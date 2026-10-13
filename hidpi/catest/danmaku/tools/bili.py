import json,sys
d=json.load(sys.stdin)["data"]; print("accept",d.get("accept_description"))
for v in d["dash"]["video"]: print(v["id"], v["codecs"], "%sx%s"%(v["width"],v["height"]), v["frameRate"], v["bandwidth"]//1000, "kbps")
