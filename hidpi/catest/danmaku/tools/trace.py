# trace.py <seconds> <out.json> : CDP trace of the browser on :9333 (gpu/viz/dawn categories), stdlib only
import sys, json, time, urllib.request, importlib.util, os
spec = importlib.util.spec_from_file_location("cdpmod", os.path.join(os.path.dirname(__file__), "cdpws.py")); c = importlib.util.module_from_spec(spec); spec.loader.exec_module(c)
ws = json.load(urllib.request.urlopen("http://127.0.0.1:9333/json/version"))["webSocketDebuggerUrl"]
s, pre = c.ws_connect(ws); r = c.R(s, pre)
cats = "gpu,gpu.dawn,disabled-by-default-gpu.dawn,viz,media,toplevel,skia,disabled-by-default-skia.gpu,disabled-by-default-gpu.service,gpu.angle"
c.send(s, json.dumps({"id": 1, "method": "Tracing.start", "params": {"traceConfig": {"includedCategories": cats.split(",")}, "transferMode": "ReportEvents"}}))
time.sleep(float(sys.argv[1])); c.send(s, json.dumps({"id": 2, "method": "Tracing.end"}))
ev = []
while True:
    m = json.loads(r.msg())
    if m.get("method") == "Tracing.dataCollected": ev += m["params"]["value"]
    elif m.get("method") == "Tracing.tracingComplete": break
json.dump(ev, open(sys.argv[2], "w")); print(len(ev), "events")
