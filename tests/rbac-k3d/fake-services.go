// fake-services: in-cluster stand-ins for tests/rbac-k3d.sh.
//
//   - :8080 Keycloak (behind Service keycloak-http, path prefix /auth): the
//     client-credentials token endpoint and the admin REST calls the
//     user-controller makes (users: query, create, get, update, delete,
//     reset-password, credentials, execute-actions-email).
//   - :18083 the EMQX management API (POST /api/v5/... answers 201), so the
//     profile-controller's EMQX plugin completes and a Profile gets its
//     finalizer.
//
// GET /__calls returns the calls seen (method, path, the user id and, for
// reset-password, the temporary flag). Password values are never stored,
// logged or returned. Standard library only; built static by the test.
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"
)

type call struct {
	Method    string `json:"method"`
	Path      string `json:"path"`
	User      string `json:"user,omitempty"`
	Temporary *bool  `json:"temporary,omitempty"`
}

var (
	mu     sync.Mutex
	users  = map[string]map[string]any{}   // id -> user representation
	creds  = map[string][]map[string]any{} // id -> credential metadata (no values)
	calls  []call
	nextID = 1
)

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/", handle)
	go func() { log.Fatal(http.ListenAndServe(":18083", mux)) }()
	log.Fatal(http.ListenAndServe(":8080", mux))
}

func reply(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	if v != nil {
		_ = json.NewEncoder(w).Encode(v)
	}
}

func record(c call) {
	calls = append(calls, c)
	if c.Temporary != nil {
		log.Printf("%s %s user=%s temporary=%v", c.Method, c.Path, c.User, *c.Temporary)
	} else {
		log.Printf("%s %s", c.Method, c.Path)
	}
}

func handle(w http.ResponseWriter, r *http.Request) {
	mu.Lock()
	defer mu.Unlock()
	p := r.URL.Path
	switch {
	case p == "/healthz":
		reply(w, 200, map[string]string{"status": "ok"})
	case p == "/__calls":
		reply(w, 200, calls)
	case strings.HasPrefix(p, "/api/v5/"):
		record(call{Method: r.Method, Path: p})
		reply(w, 201, map[string]any{})
	case r.Method == http.MethodPost && strings.HasSuffix(p, "/protocol/openid-connect/token"):
		record(call{Method: r.Method, Path: p})
		reply(w, 200, map[string]any{
			"access_token": "fake-access-token", "expires_in": 300, "refresh_expires_in": 0,
			"token_type": "Bearer", "not-before-policy": 0, "scope": "profile email",
		})
	case strings.HasPrefix(p, "/auth/admin/realms/"):
		admin(w, r, strings.Split(strings.TrimPrefix(p, "/auth/admin/realms/"), "/"))
	default:
		record(call{Method: r.Method, Path: p})
		reply(w, 404, map[string]string{"error": "not found"})
	}
}

// admin handles /auth/admin/realms/<realm>/<parts...>.
func admin(w http.ResponseWriter, r *http.Request, parts []string) {
	c := call{Method: r.Method, Path: r.URL.Path}
	if len(parts) < 2 || parts[1] != "users" {
		record(c)
		if r.Method == http.MethodGet {
			reply(w, 200, []any{})
		} else {
			reply(w, 204, nil)
		}
		return
	}
	switch {
	case len(parts) == 2 && r.Method == http.MethodGet: // query
		record(c)
		q := r.URL.Query()
		out := []map[string]any{}
		for _, u := range users {
			if match(u, "email", q.Get("email"), q.Get("exact") == "true") &&
				match(u, "username", q.Get("username"), q.Get("exact") == "true") {
				out = append(out, u)
			}
		}
		reply(w, 200, out)
	case len(parts) == 2 && r.Method == http.MethodPost: // create
		var u map[string]any
		if err := json.NewDecoder(r.Body).Decode(&u); err != nil {
			record(c)
			reply(w, 400, map[string]string{"error": err.Error()})
			return
		}
		id := fmt.Sprintf("u%04d", nextID)
		nextID++
		u["id"] = id
		u["createdTimestamp"] = time.Now().UnixMilli()
		if _, ok := u["requiredActions"]; !ok {
			u["requiredActions"] = []string{}
		}
		delete(u, "credentials")
		users[id] = u
		c.User = id
		record(c)
		w.Header().Set("Location", "http://"+r.Host+r.URL.Path+"/"+id)
		reply(w, 201, nil)
	case len(parts) == 3 && parts[2] == "count":
		record(c)
		reply(w, 200, len(users))
	case len(parts) >= 3:
		id := parts[2]
		c.User = id
		u, ok := users[id]
		if !ok {
			record(c)
			reply(w, 404, map[string]string{"error": "User not found"})
			return
		}
		sub := strings.Join(parts[3:], "/")
		switch {
		case sub == "" && r.Method == http.MethodGet:
			record(c)
			reply(w, 200, u)
		case sub == "" && r.Method == http.MethodPut:
			var upd map[string]any
			_ = json.NewDecoder(r.Body).Decode(&upd)
			for k, v := range upd {
				if k != "id" && k != "credentials" {
					u[k] = v
				}
			}
			record(c)
			reply(w, 204, nil)
		case sub == "" && r.Method == http.MethodDelete:
			delete(users, id)
			delete(creds, id)
			record(c)
			reply(w, 204, nil)
		case sub == "reset-password" && r.Method == http.MethodPut:
			var body struct {
				Temporary bool `json:"temporary"`
			}
			_ = json.NewDecoder(r.Body).Decode(&body) // the value is read and dropped
			t := body.Temporary
			c.Temporary = &t
			creds[id] = []map[string]any{{
				"id": fmt.Sprintf("c-%s-%d", id, time.Now().UnixNano()), "type": "password",
				"createdDate": time.Now().UnixMilli(), "temporary": t,
			}}
			ra := []any{}
			if t {
				ra = append(ra, "UPDATE_PASSWORD")
			}
			u["requiredActions"] = ra
			record(c)
			reply(w, 204, nil)
		case sub == "credentials" && r.Method == http.MethodGet:
			record(c)
			out := creds[id]
			if out == nil {
				out = []map[string]any{}
			}
			reply(w, 200, out)
		case strings.HasPrefix(sub, "credentials/") && r.Method == http.MethodDelete:
			delete(creds, id)
			record(c)
			reply(w, 204, nil)
		default: // execute-actions-email, groups, role-mappings, ...
			record(c)
			if r.Method == http.MethodGet {
				reply(w, 200, []any{})
			} else {
				reply(w, 204, nil)
			}
		}
	default:
		record(c)
		reply(w, 204, nil)
	}
}

// match: Keycloak's query semantics, case-insensitive substring unless exact.
func match(u map[string]any, field, want string, exact bool) bool {
	if want == "" {
		return true
	}
	have, _ := u[field].(string)
	have, want = strings.ToLower(have), strings.ToLower(want)
	if exact {
		return have == want
	}
	return strings.Contains(have, want)
}
