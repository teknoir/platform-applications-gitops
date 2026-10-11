// Command vdev-spike-render renders the tnctl server bootstrap for one Device.
//
// It is compiled by render.sh inside a copy of github.com/teknoir/cli at a pinned
// commit (module path "teknoir/cli"), so it uses that commit's real
// pkg/templates.ServerTemplate and its partials. There is no fork of the script.
//
// TemplateData is filled the way `tnctl bootstrap` fills it (cli cmd/bootstrap.go):
// the keys come from the Device's spec.keys.data (Backstage serves the same map to
// tnctl as the catalog entity's spec.settings), the k3s token is 16 random bytes
// hex-encoded, and DockerSecret is empty (tnctl's --docker-secret default).
//
// The rendered script contains the device private key, the device user's password
// and the k3s token. It is written with mode 0600 to -out and never printed. stdout
// carries only a non-secret JSON summary.
package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"regexp"
	"strings"

	"teknoir/cli/pkg/templates"
)

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

var dnsLabel = regexp.MustCompile(`^[a-z0-9]([-a-z0-9]*[a-z0-9])?$`)

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "vdev-spike-render: "+format+"\n", args...)
	os.Exit(1)
}

func decode(data map[string]string, key string, required bool) string {
	v, ok := data[key]
	if !ok || v == "" {
		if required {
			fail("spec.keys.data.%s is missing or empty", key)
		}
		return ""
	}
	b, err := base64.StdEncoding.DecodeString(v)
	if err != nil {
		// Never include the value in the error.
		fail("spec.keys.data.%s is not valid base64", key)
	}
	return string(b)
}

func main() {
	devicePath := flag.String("device-json", "", "Device object as JSON (kubectl get device -o json)")
	domain := flag.String("domain", "", "platform domain, e.g. teknoir.cloud")
	out := flag.String("out", "", "path of the rendered server script (created 0600, must not exist)")
	flag.Parse()
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
	if !dnsLabel.MatchString(d.Metadata.Name) || len(d.Metadata.Name) > 58 {
		fail("device name %q must be a DNS label of at most 58 characters", d.Metadata.Name)
	}
	if !dnsLabel.MatchString(d.Metadata.Namespace) {
		fail("device namespace %q is not a DNS label", d.Metadata.Namespace)
	}

	keys := d.Spec.Keys.Data
	if keys == nil {
		fail("spec.keys.data is missing")
	}
	rsaPrivate := decode(keys, "rsa_private", true)
	rsaPublic := decode(keys, "rsa_public", true)
	username := decode(keys, "username", true)
	password := decode(keys, "userpassword", false)
	publicSSHKey := decode(keys, "publicsshkey", false)
	if !strings.Contains(rsaPrivate, "PRIVATE KEY-----") {
		fail("spec.keys.data.rsa_private does not decode to a PEM private key")
	}

	token := make([]byte, 16)
	if _, err := rand.Read(token); err != nil {
		fail("generate k3s token: %v", err)
	}

	data := templates.TemplateData{
		Domain:       *domain,
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

	f, err := os.OpenFile(*out, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		fail("create output: %v", err)
	}
	var buf strings.Builder
	if err := templates.ServerTemplate.Execute(&buf, data); err != nil {
		f.Close()
		os.Remove(*out)
		fail("render server template: %v", err)
	}
	if _, err := f.WriteString(buf.String()); err != nil {
		f.Close()
		os.Remove(*out)
		fail("write output: %v", err)
	}
	if err := f.Close(); err != nil {
		fail("close output: %v", err)
	}

	sum := sha256.Sum256([]byte(templates.ServerTemplateStr))
	s := summary{
		Device:          d.Metadata.Name,
		Namespace:       d.Metadata.Namespace,
		Domain:          *domain,
		DeviceType:      d.Spec.DeviceType,
		Template:        "pkg/templates/server.sh.tmpl",
		TemplateSHA256:  hex.EncodeToString(sum[:]),
		ScriptBytes:     buf.Len(),
		HasPublicSSHKey: publicSSHKey != "",
		HasPassword:     password != "",
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	if err := enc.Encode(s); err != nil {
		fail("write summary: %v", err)
	}
}
