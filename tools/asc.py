"""Small App Store Connect API helper used by CI (stdlib + PyJWT).

Never prints credentials. Subcommands:
  check-app   <bundle>                         fail unless the app record exists
  min-version <bundle> <version>               fail if <version> is below TestFlight's highest
  wait        <bundle> <build>                 poll processing → prints FINAL_STATE
  testable    <bundle> <build>                 answer compliance, give internal testers access
"""
import json, os, sys, time, urllib.error, urllib.request
import jwt

API = "https://api.appstoreconnect.apple.com"
KEY = open(os.path.expanduser(f"~/private_keys/AuthKey_{os.environ['KEY_ID']}.p8")).read()

def call(path, method="GET", body=None):
    now = int(time.time())
    tok = jwt.encode({"iss": os.environ["ISSUER"], "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"},
                     KEY, algorithm="ES256", headers={"kid": os.environ["KEY_ID"], "typ": "JWT"})
    req = urllib.request.Request(API + path, method=method, data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": f"Bearer {tok}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        print(f"{method} {path.split('?')[0]}: HTTP {e.code} {e.read().decode()[:400]}")
        return None

def app_id(bundle):
    r = call(f"/v1/apps?filter[bundleId]={bundle}")
    if not r or not r["data"]:
        sys.exit(f"No App Store Connect app for {bundle}. Create it once: App Store Connect → My Apps → + → New App "
                 f"(platform iOS, bundle ID {bundle}). Apple's API can't create app records.")
    return r["data"][0]["id"]

def vkey(v): return tuple(int(x) for x in v.split("."))

cmd, bundle = sys.argv[1], sys.argv[2]
app = app_id(bundle)
if cmd == "check-app":
    print("App record:", app)
elif cmd == "min-version":
    want = sys.argv[3]
    r = call(f"/v1/preReleaseVersions?filter[app]={app}&limit=200&fields[preReleaseVersions]=version") or {"data": []}
    seen = [v["attributes"]["version"] for v in r["data"]]
    top = max(seen, key=vkey) if seen else "0"
    print("Highest version on TestFlight:", top)
    if vkey(want) < vkey(top):
        sys.exit(f"{want} is lower than {top}: testers would never be offered it. Use a higher version.")
elif cmd == "wait":
    build, state = sys.argv[3], "NOT FOUND"
    for _ in range(80):
        r = call(f"/v1/builds?filter[app]={app}&filter[version]={build}&fields[builds]=version,processingState,uploadedDate")
        if r and r["data"]:
            a = r["data"][0]["attributes"]; state = a["processingState"]
            print(f"build {a['version']}: {state}", flush=True)
            if state != "PROCESSING": break
        else:
            print(f"build {build}: not visible yet", flush=True)
        time.sleep(30)
    print("FINAL_STATE", state)
    sys.exit(0 if state == "VALID" else 1)
elif cmd == "testable":
    build = sys.argv[3]
    r = call(f"/v1/builds?filter[app]={app}&filter[version]={build}")
    if not r or not r["data"]: sys.exit(f"build {build} not found")
    bid = r["data"][0]["id"]; a = r["data"][0]["attributes"]
    if a.get("usesNonExemptEncryption") is None:
        ok = call(f"/v1/builds/{bid}", "PATCH", {"data": {"type": "builds", "id": bid, "attributes": {"usesNonExemptEncryption": False}}})
        print("export compliance answered:", "yes" if ok is not None else "FAILED")
    groups = (call(f"/v1/apps/{app}/betaGroups?limit=50") or {"data": []})["data"]
    group = next((g for g in groups if g["attributes"]["isInternalGroup"]), None)
    if not group:
        g = call("/v1/betaGroups", "POST", {"data": {"type": "betaGroups", "attributes": {"name": "Musa Team", "isInternalGroup": True, "hasAccessToAllBuilds": True},
                                                     "relationships": {"app": {"data": {"type": "apps", "id": app}}}}})
        group = g and g["data"]
        print("created internal group 'Musa Team':", "yes" if group else "FAILED")
    if group:
        gid = group["id"]
        if not group["attributes"].get("hasAccessToAllBuilds"):
            call(f"/v1/betaGroups/{gid}/relationships/builds", "POST", {"data": [{"type": "builds", "id": bid}]})
        have = {t["attributes"].get("email", "").lower() for t in (call(f"/v1/betaGroups/{gid}/betaTesters?limit=200") or {"data": []})["data"]}
        # Same people who test the other Musa apps: copy testers from every other app's internal groups.
        wanted = {}
        for other in (call("/v1/apps?limit=50&fields[apps]=bundleId") or {"data": []})["data"]:
            if other["id"] == app: continue
            for og in (call(f"/v1/apps/{other['id']}/betaGroups?limit=50") or {"data": []})["data"]:
                if not og["attributes"]["isInternalGroup"]: continue
                for t in (call(f"/v1/betaGroups/{og['id']}/betaTesters?limit=200") or {"data": []})["data"]:
                    em = (t["attributes"].get("email") or "").lower()
                    if em: wanted[em] = t
        for em, t in wanted.items():
            if em in have: continue
            r = call("/v1/betaTesters", "POST", {"data": {"type": "betaTesters", "attributes": {"email": em, "firstName": t["attributes"].get("firstName") or "", "lastName": t["attributes"].get("lastName") or ""},
                                                       "relationships": {"betaGroups": {"data": [{"type": "betaGroups", "id": gid}]}}}})
            if r is None:  # tester exists already: link them
                r = call(f"/v1/betaGroups/{gid}/relationships/betaTesters", "POST", {"data": [{"type": "betaTesters", "id": t["id"]}]})
            masked = em[:3] + "***" + em[em.find("@"):]
            print(f"tester {masked}: {'added' if r is not None else 'FAILED'}")
        testers = (call(f"/v1/betaGroups/{gid}/betaTesters?limit=200") or {"data": []})["data"]
        print(f"group '{group['attributes']['name']}' testers: {len(testers)}")
    time.sleep(15)
    d = call(f"/v1/builds/{bid}/buildBetaDetail")
    if d:
        da = d["data"]["attributes"]
        print("INTERNAL_STATE", da.get("internalBuildState"), "EXTERNAL_STATE", da.get("externalBuildState"))
