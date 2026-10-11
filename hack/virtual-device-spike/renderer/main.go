// Command vdev-spike-render renders the tnctl server bootstrap and the cloud-init user
// data of one virtual Device.
//
// It is compiled inside a copy of github.com/teknoir/cli at a pinned commit (module
// path "teknoir/cli"), by render.sh and by renderer/Dockerfile, so it uses that
// commit's real pkg/templates.ServerTemplate and its partials. There is no fork of
// the script.
//
// Three modes:
//
//	(default)    -device-json F -domain D -out F
//	             Render the tnctl server script for the Device in F (kubectl get device -o
//	             json), the way `tnctl bootstrap` does (cli cmd/bootstrap.go). The keys come
//	             from spec.keys.data (Backstage serves the same map to tnctl as the catalog
//	             entity's spec.settings), the k3s token is 16 random bytes hex-encoded and
//	             DockerSecret is empty (tnctl's --docker-secret default).
//	-userdata    -script F -device N -namespace NS -domain D ... -out F
//	             Render the cloud-init user data (userdata.tmpl) around an existing script.
//	-in-cluster  -device N -namespace NS -vdev-namespace NS-vdev -domain D ...
//	             Run as a Kubernetes Job (ServiceAccount token, standard library only):
//	             if Secret <device>-cloudinit exists in the vdev namespace, do nothing;
//	             otherwise GET the Device, render both in memory and POST the Secret. The
//	             k3s token is generated once, so a re-sync never changes it. No file with a
//	             credential is ever written and nothing secret is logged.
//
// The rendered script contains the device private key, the device user's password and
// the k3s token. Files are created 0600. stdout carries only a non-secret summary.
package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	_ "embed"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"
	"text/template"
	"time"

	"teknoir/cli/pkg/templates"
)

//go:embed userdata.tmpl
var userdataTmplStr string

type device struct {
	Metadata struct {
		Name      string `json:"name"`
		Namespace string `json:"namespace"`
	} `json:"metadata"`
	Spec struct {
		DeviceType string `json:"device_type"`
		Keys       struct {
			Data map[string]string `json:"data"`
		} `json:"keys"`
	} `json:"spec"`
}

type summary struct {
	Device          string `json:"device"`
	Namespace       string `json:"namespace"`
	Domain          string `json:"domain"`
	DeviceType      string `json:"deviceType"`
	Template        string `json:"template"`
	TemplateSHA256  string `json:"templateSha256"`
	ScriptBytes     int    `json:"scriptBytes"`
	HasPublicSSHKey bool   `json:"hasPublicSshKey"`
	HasPassword     bool   `json:"hasPassword"`
}

// userdataParams are the inputs of userdata.tmpl. Every value is validated before it
// is rendered, so none can break out of the YAML or the single-quoted shell words.
type userdataParams struct {
	Device      string
	Namespace   string
	Domain      string
	K3SVersion  string
	K3SExec     string
	ClusterCIDR string
	ServiceCIDR string
	ClusterDNS  string
	CLIRef      string
	RenderedAt  string
	DebugPubkey string
	ScriptB64   string
}

var (
	dnsLabel   = regexp.MustCompile(`^[a-z0-9]([-a-z0-9]*[a-z0-9])?$`)
	dnsName    = regexp.MustCompile(`^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)+$`)
	k3sRelease = regexp.MustCompile(`^v1\.([0-9]+)\.([0-9]+)\+k3s[0-9]+$`)
	gitSHA     = regexp.MustCompile(`^[0-9a-f]{40}$`)
	sshPubKey  = regexp.MustCompile(`^(ssh-[a-z0-9]+|ecdsa-sha2-[a-z0-9]+) [A-Za-z0-9+/=]+( [^\n']*)?$`)
)

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "vdev-spike-render: "+format+"\n", args...)
	os.Exit(1)
}

func logf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "vdev-spike-render: "+format+"\n", args...)
}

func decode(data map[string]string, key string, required bool) (string, error) {
	v, ok := data[key]
	if !ok || v == "" {
		if required {
			return "", fmt.Errorf("spec.keys.data.%s is missing or empty", key)
		}
		return "", nil
	}
	b, err := base64.StdEncoding.DecodeString(v)
	if err != nil {
		// Never include the value in the error.
		return "", fmt.Errorf("spec.keys.data.%s is not valid base64", key)
	}
	return string(b), nil
}

func validateDevice(d *device) error {
	if !dnsLabel.MatchString(d.Metadata.Name) || len(d.Metadata.Name) > 58 {
		return fmt.Errorf("device name %q must be a DNS label of at most 58 characters", d.Metadata.Name)
	}
	if !dnsLabel.MatchString(d.Metadata.Namespace) || len(d.Metadata.Namespace) > 63 {
		return fmt.Errorf("device namespace %q is not a DNS label", d.Metadata.Namespace)
	}
	return nil
}

// renderBootstrap renders the tnctl server script for d.
func renderBootstrap(d *device, domain string) (string, summary, error) {
	var s summary
	keys := d.Spec.Keys.Data
	if keys == nil {
		return "", s, errors.New("spec.keys.data is missing")
	}
	rsaPrivate, err := decode(keys, "rsa_private", true)
	if err != nil {
		return "", s, err
	}
	rsaPublic, err := decode(keys, "rsa_public", true)
	if err != nil {
		return "", s, err
	}
	username, err := decode(keys, "username", true)
	if err != nil {
		return "", s, err
	}
	password, err := decode(keys, "userpassword", false)
	if err != nil {
		return "", s, err
	}
	publicSSHKey, err := decode(keys, "publicsshkey", false)
	if err != nil {
		return "", s, err
	}
	if !strings.Contains(rsaPrivate, "PRIVATE KEY-----") {
		return "", s, errors.New("spec.keys.data.rsa_private does not decode to a PEM private key")
	}

	token := make([]byte, 16)
	if _, err := rand.Read(token); err != nil {
		return "", s, fmt.Errorf("generate k3s token: %v", err)
	}

	data := templates.TemplateData{
		Domain:       domain,
		Namespace:    d.Metadata.Namespace,
		DeviceID:     d.Metadata.Name,
		RSAPrivate:   rsaPrivate,
		RSAPublic:    rsaPublic,
		Username:     username,
		Password:     password,
		PublicSSHKey: publicSSHKey,
		K3SToken:     hex.EncodeToString(token),
		DockerSecret: "",
	}
	var buf strings.Builder
	if err := templates.ServerTemplate.Execute(&buf, data); err != nil {
		return "", s, fmt.Errorf("render server template: %v", err)
	}
	sum := sha256.Sum256([]byte(templates.ServerTemplateStr))
	s = summary{
		Device:          d.Metadata.Name,
		Namespace:       d.Metadata.Namespace,
		Domain:          domain,
		DeviceType:      d.Spec.DeviceType,
		Template:        "pkg/templates/server.sh.tmpl",
		TemplateSHA256:  hex.EncodeToString(sum[:]),
		ScriptBytes:     buf.Len(),
		HasPublicSSHKey: publicSSHKey != "",
		HasPassword:     password != "",
	}
	return buf.String(), s, nil
}

// checkScript is the structural check of render.sh on the rendered script; it names
// the failing check and never prints content.
func checkScript(script, dev, ns, domain string) error {
	if !strings.HasPrefix(script, "#!/bin/sh\n") {
		return errors.New("rendered script does not start with #!/bin/sh")
	}
	for _, c := range []struct{ name, want string }{
		{"_DEVICE_ID", "\n_DEVICE_ID=\"" + dev + "\"\n"},
		{"_NAMESPACE", "\n_NAMESPACE=\"" + ns + "\"\n"},
		{"_DOMAIN", "\n_DOMAIN=\"" + domain + "\"\n"},
	} {
		if !strings.Contains(script, c.want) {
			return fmt.Errorf("rendered script does not set %s to the expected value (template changed?)", c.name)
		}
	}
	if !strings.Contains(script, `INSTALL_K3S_EXEC="server --token`) {
		return errors.New("rendered script does not pass INSTALL_K3S_EXEC through (template changed?)")
	}
	if !strings.Contains(script, "CREATE_USER=${CREATE_USER:-ask}") {
		return errors.New("rendered script has no CREATE_USER switch (template changed?)")
	}
	if strings.Contains(script, "{{") {
		return errors.New("rendered script contains unrendered template markers")
	}
	return nil
}

// k3sPrunesNonCertSignRoots reports whether the k3s release ignores CA certificates
// without keyCertSign when it validates its own /cacerts (k3s 6c7a974, v1.34.12,
// v1.35.9, v1.36.5 and later). Anything that is not a release tag counts as yes.
func k3sPrunesNonCertSignRoots(v string) bool {
	m := k3sRelease.FindStringSubmatch(v)
	if m == nil {
		return true
	}
	minor, _ := strconv.Atoi(m[1])
	patch, _ := strconv.Atoi(m[2])
	switch {
	case minor >= 37:
		return true
	case minor == 36:
		return patch >= 5
	case minor == 35:
		return patch >= 9
	case minor == 34:
		return patch >= 12
	}
	return false
}

// deviceCertHasCertSign reports whether spec.keys.data.rsa_public decodes to a
// certificate with the keyCertSign key usage.
func deviceCertHasCertSign(d *device) bool {
	raw, err := decode(d.Spec.Keys.Data, "rsa_public", true)
	if err != nil {
		return false
	}
	rest := []byte(raw)
	for {
		var blk *pem.Block
		blk, rest = pem.Decode(rest)
		if blk == nil {
			return false
		}
		if blk.Type != "CERTIFICATE" {
			continue
		}
		c, err := x509.ParseCertificate(blk.Bytes)
		if err != nil {
			return false
		}
		return c.KeyUsage&x509.KeyUsageCertSign != 0
	}
}

func (p *userdataParams) validate() error {
	if !dnsLabel.MatchString(p.Device) || len(p.Device) > 58 {
		return fmt.Errorf("device %q is not a DNS label of at most 58 characters", p.Device)
	}
	if !dnsLabel.MatchString(p.Namespace) {
		return fmt.Errorf("namespace %q is not a DNS label", p.Namespace)
	}
	if !dnsName.MatchString(p.Domain) {
		return fmt.Errorf("domain %q is not a DNS name", p.Domain)
	}
	if !k3sRelease.MatchString(p.K3SVersion) {
		return fmt.Errorf("k3s version %q is not a k3s release tag", p.K3SVersion)
	}
	for _, c := range []string{p.ClusterCIDR, p.ServiceCIDR} {
		if _, _, err := net.ParseCIDR(c); err != nil {
			return fmt.Errorf("%q is not a CIDR", c)
		}
	}
	if net.ParseIP(p.ClusterDNS) == nil {
		return fmt.Errorf("cluster DNS %q is not an IP address", p.ClusterDNS)
	}
	if !gitSHA.MatchString(p.CLIRef) {
		return fmt.Errorf("cli ref %q is not a full commit SHA", p.CLIRef)
	}
	if _, err := time.Parse(time.RFC3339, p.RenderedAt); err != nil {
		return fmt.Errorf("rendered-at %q is not RFC 3339", p.RenderedAt)
	}
	if p.DebugPubkey != "" && !sshPubKey.MatchString(p.DebugPubkey) {
		return errors.New("debug public key is not an SSH public key line")
	}
	p.K3SExec = fmt.Sprintf("--cluster-cidr=%s --service-cidr=%s --cluster-dns=%s", p.ClusterCIDR, p.ServiceCIDR, p.ClusterDNS)
	return nil
}

func renderUserdata(p userdataParams, script string) (string, error) {
	if err := p.validate(); err != nil {
		return "", err
	}
	p.ScriptB64 = base64.StdEncoding.EncodeToString([]byte(script))
	t, err := template.New("userdata").Option("missingkey=error").Parse(userdataTmplStr)
	if err != nil {
		return "", fmt.Errorf("parse userdata template: %v", err)
	}
	var buf bytes.Buffer
	if err := t.Execute(&buf, p); err != nil {
		return "", fmt.Errorf("render userdata: %v", err)
	}
	return buf.String(), nil
}

// writeNew creates path (mode 0600, must not exist) with content.
func writeNew(path, content string) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return fmt.Errorf("create output: %v", err)
	}
	if _, err := f.WriteString(content); err != nil {
		f.Close()
		os.Remove(path)
		return fmt.Errorf("write output: %v", err)
	}
	if err := f.Close(); err != nil {
		os.Remove(path)
		return fmt.Errorf("close output: %v", err)
	}
	return nil
}

func printJSON(v any) {
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	if err := enc.Encode(v); err != nil {
		fail("write summary: %v", err)
	}
}

// ------------------------------------------------------------------ in-cluster

type kubeClient struct {
	base  string
	token string
	http  *http.Client
}

func newKubeClient(apiURL, tokenFile, caFile string) (*kubeClient, error) {
	if apiURL == "" {
		host, port := os.Getenv("KUBERNETES_SERVICE_HOST"), os.Getenv("KUBERNETES_SERVICE_PORT")
		if host == "" || port == "" {
			return nil, errors.New("KUBERNETES_SERVICE_HOST/PORT are not set (not running in a pod?)")
		}
		apiURL = "https://" + net.JoinHostPort(host, port)
	}
	tok, err := os.ReadFile(tokenFile)
	if err != nil {
		return nil, fmt.Errorf("read service account token: %v", err)
	}
	ca, err := os.ReadFile(caFile)
	if err != nil {
		return nil, fmt.Errorf("read cluster CA: %v", err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(ca) {
		return nil, errors.New("cluster CA file has no certificate")
	}
	return &kubeClient{
		base:  strings.TrimRight(apiURL, "/"),
		token: strings.TrimSpace(string(tok)),
		http: &http.Client{
			Timeout:   30 * time.Second,
			Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12}},
		},
	}, nil
}

// do sends one request and returns the status and body. The body is returned to the
// caller only; errors name the status and the Status object's reason, never a body.
func (k *kubeClient) do(ctx context.Context, method, path string, body []byte) (int, []byte, error) {
	var rd io.Reader
	if body != nil {
		rd = bytes.NewReader(body)
	}
	req, err := http.NewRequestWithContext(ctx, method, k.base+path, rd)
	if err != nil {
		return 0, nil, err
	}
	req.Header.Set("Authorization", "Bearer "+k.token)
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := k.http.Do(req)
	if err != nil {
		// url.Error carries the URL and the cause, no headers or body.
		var ue *url.Error
		if errors.As(err, &ue) {
			return 0, nil, fmt.Errorf("%s %s: %v", method, path, ue.Err)
		}
		return 0, nil, fmt.Errorf("%s %s failed", method, path)
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return 0, nil, fmt.Errorf("%s %s: read response: %v", method, path, err)
	}
	return resp.StatusCode, b, nil
}

func statusReason(b []byte) string {
	var st struct {
		Reason string `json:"reason"`
	}
	if json.Unmarshal(b, &st) == nil && st.Reason != "" {
		return st.Reason
	}
	return "unknown"
}

type inClusterOpts struct {
	apiURL, tokenFile, caFile string
	vdevNamespace             string
	domain                    string
	params                    userdataParams
}

func runInCluster(o inClusterOpts) error {
	p := o.params
	if err := p.validate(); err != nil {
		return err
	}
	if !dnsLabel.MatchString(o.vdevNamespace) {
		return fmt.Errorf("vdev namespace %q is not a DNS label", o.vdevNamespace)
	}
	k, err := newKubeClient(o.apiURL, o.tokenFile, o.caFile)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	secretName := p.Device + "-cloudinit"
	secretPath := "/api/v1/namespaces/" + o.vdevNamespace + "/secrets"

	// 1. An existing Secret wins: the k3s token inside it belongs to the running VM.
	code, body, err := k.do(ctx, http.MethodGet, secretPath+"/"+secretName, nil)
	if err != nil {
		return err
	}
	switch code {
	case http.StatusOK:
		logf("secret %s/%s exists; nothing to do", o.vdevNamespace, secretName)
		return nil
	case http.StatusNotFound:
	default:
		return fmt.Errorf("GET secret %s/%s: HTTP %d (%s)", o.vdevNamespace, secretName, code, statusReason(body))
	}

	// 2. The Device.
	devPath := "/apis/teknoir.org/v1/namespaces/" + p.Namespace + "/devices/" + p.Device
	code, body, err = k.do(ctx, http.MethodGet, devPath, nil)
	if err != nil {
		return err
	}
	if code != http.StatusOK {
		return fmt.Errorf("GET device %s/%s: HTTP %d (%s); create it in Backstage first", p.Namespace, p.Device, code, statusReason(body))
	}
	var d device
	if err := json.Unmarshal(body, &d); err != nil {
		return errors.New("parse Device JSON failed")
	}
	if d.Metadata.Name != p.Device || d.Metadata.Namespace != p.Namespace {
		return fmt.Errorf("the API returned a different Device than %s/%s", p.Namespace, p.Device)
	}
	if err := validateDevice(&d); err != nil {
		return err
	}
	if k3sPrunesNonCertSignRoots(p.K3SVersion) && !deviceCertHasCertSign(&d) {
		return fmt.Errorf("k3s %s cannot start with this device's certificate as root CA: it has no keyCertSign key usage (Backstage-generated device certificates never do); use a k3s release before v1.34.12/v1.35.9/v1.36.5", p.K3SVersion)
	}

	// 3. Render in memory.
	script, _, err := renderBootstrap(&d, o.domain)
	if err != nil {
		return err
	}
	if err := checkScript(script, p.Device, p.Namespace, o.domain); err != nil {
		return err
	}
	p.Domain = o.domain
	p.RenderedAt = time.Now().UTC().Format(time.RFC3339)
	userdata, err := renderUserdata(p, script)
	if err != nil {
		return err
	}

	// 4. Create (never update) the Secret.
	secret := map[string]any{
		"apiVersion": "v1",
		"kind":       "Secret",
		"metadata": map[string]any{
			"name":      secretName,
			"namespace": o.vdevNamespace,
			"labels": map[string]string{
				"teknoir.org/teamspace":        p.Namespace,
				"teknoir.org/component":        "virtual-device",
				"teknoir.org/spike":            "s1",
				"teknoir.org/device":           p.Device,
				"app.kubernetes.io/managed-by": "vd-spike-kit",
			},
		},
		"type": "Opaque",
		"data": map[string]string{"userdata": base64.StdEncoding.EncodeToString([]byte(userdata))},
	}
	payload, err := json.Marshal(secret)
	if err != nil {
		return errors.New("encode Secret failed")
	}
	code, body, err = k.do(ctx, http.MethodPost, secretPath+"?fieldManager=vdev-spike-render", payload)
	if err != nil {
		return err
	}
	switch code {
	case http.StatusCreated, http.StatusOK:
		logf("created secret %s/%s (%d bytes of user data)", o.vdevNamespace, secretName, len(userdata))
		return nil
	case http.StatusConflict:
		logf("secret %s/%s was created meanwhile; nothing to do", o.vdevNamespace, secretName)
		return nil
	}
	return fmt.Errorf("POST secret %s/%s: HTTP %d (%s)", o.vdevNamespace, secretName, code, statusReason(body))
}

// ------------------------------------------------------------------ main

func main() {
	var (
		userdataMode = flag.Bool("userdata", false, "render the cloud-init user data around -script")
		inCluster    = flag.Bool("in-cluster", false, "create Secret <device>-cloudinit from the Device (runs as a Job)")

		devicePath = flag.String("device-json", "", "Device object as JSON (kubectl get device -o json)")
		domain     = flag.String("domain", "", "platform domain, e.g. teknoir.cloud")
		out        = flag.String("out", "", "path of the rendered file (created 0600, must not exist)")
		scriptPath = flag.String("script", "", "-userdata: the rendered server script")

		dev       = flag.String("device", "", "-userdata, -in-cluster: Device name")
		ns        = flag.String("namespace", "", "-userdata, -in-cluster: teamspace")
		vdevNS    = flag.String("vdev-namespace", "", "-in-cluster: namespace of the Secret (<teamspace>-vdev)")
		k3sVer    = flag.String("k3s-version", "", "inner k3s release, e.g. v1.34.11+k3s1")
		clusterC  = flag.String("cluster-cidr", "", "inner k3s pod CIDR")
		serviceC  = flag.String("service-cidr", "", "inner k3s service CIDR")
		clusterDN = flag.String("cluster-dns", "", "inner k3s cluster DNS address")
		cliRef    = flag.String("cli-ref", "", "teknoir/cli commit of the bootstrap templates")
		renderedA = flag.String("rendered-at", "", "-userdata: RFC 3339 timestamp (default: now)")
		debugKey  = flag.String("debug-pubkey", "", "-userdata: SSH public key of a break-glass user 'vdspike'")

		apiURL    = flag.String("api-url", "", "-in-cluster: API server URL (default: from KUBERNETES_SERVICE_HOST/PORT)")
		tokenFile = flag.String("token-file", "/var/run/secrets/kubernetes.io/serviceaccount/token", "-in-cluster: service account token")
		caFile    = flag.String("ca-file", "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt", "-in-cluster: cluster CA bundle")
	)
	flag.Parse()

	params := userdataParams{
		Device: *dev, Namespace: *ns, Domain: *domain,
		K3SVersion: *k3sVer, ClusterCIDR: *clusterC, ServiceCIDR: *serviceC, ClusterDNS: *clusterDN,
		CLIRef: *cliRef, RenderedAt: *renderedA, DebugPubkey: *debugKey,
	}
	if params.RenderedAt == "" {
		params.RenderedAt = time.Now().UTC().Format(time.RFC3339)
	}

	switch {
	case *userdataMode && *inCluster:
		fail("-userdata and -in-cluster are exclusive")

	case *inCluster:
		if *domain == "" {
			fail("-domain is required")
		}
		if err := runInCluster(inClusterOpts{
			apiURL: *apiURL, tokenFile: *tokenFile, caFile: *caFile,
			vdevNamespace: *vdevNS, domain: *domain, params: params,
		}); err != nil {
			fail("%v", err)
		}

	case *userdataMode:
		if *scriptPath == "" || *out == "" {
			fail("-script and -out are required")
		}
		script, err := os.ReadFile(*scriptPath)
		if err != nil {
			fail("read script: %v", err)
		}
		ud, err := renderUserdata(params, string(script))
		if err != nil {
			fail("%v", err)
		}
		if err := writeNew(*out, ud); err != nil {
			fail("%v", err)
		}

	default:
		if *devicePath == "" || *domain == "" || *out == "" {
			fail("-device-json, -domain and -out are required")
		}
		raw, err := os.ReadFile(*devicePath)
		if err != nil {
			fail("read device: %v", err)
		}
		var d device
		if err := json.Unmarshal(raw, &d); err != nil {
			fail("parse device JSON: %v", err)
		}
		if err := validateDevice(&d); err != nil {
			fail("%v", err)
		}
		script, s, err := renderBootstrap(&d, *domain)
		if err != nil {
			fail("%v", err)
		}
		if err := writeNew(*out, script); err != nil {
			fail("%v", err)
		}
		printJSON(s)
	}
}
