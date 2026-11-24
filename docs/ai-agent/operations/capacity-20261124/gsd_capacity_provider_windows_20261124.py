"""Run exactly one hash-pinned provider phase; never advance automatically."""
import argparse,datetime,hashlib,json,os,pathlib,subprocess,sys
BASE=pathlib.Path(r"C:\Users\DAVID\AppData\Local\Temp\gsd-oci-target-map-20261124-1bf4pgbe")
PYTHON=BASE/"sdk-env-bounded-expansion/Scripts/python.exe"
SOURCE=BASE/"bounded-expansion-code/gsd_capacity_provider_20261124.py"
EXPECTED_SHA="120f7c47e7060d030bfecc5c4b6a5e0d8ec5251d5d2811f6d76e1c10ecd90594"

def main():
 parser=argparse.ArgumentParser(description=__doc__)
 parser.add_argument("--phase",required=True,choices=["preflight","backup-root","backup-data","backups-status","resize-root","resize-data","verify"])
 parser.add_argument("--execute",action="store_true")
 args=parser.parse_args()
 if not PYTHON.is_file() or hashlib.sha256(SOURCE.read_bytes()).hexdigest()!=EXPECTED_SHA:
  print(json.dumps({"status":"FAILED","error_code":"PINNED_EXECUTOR_OR_SDK_MISSING"}));return 1
 command=[str(PYTHON),str(SOURCE),"--phase",args.phase]
 if args.execute:command.append("--execute")
 try:
  child=subprocess.run(command,capture_output=True,text=True,encoding="utf-8",timeout=240)
  child_exit=child.returncode
  try:result=json.loads(child.stdout)
  except Exception:result={"status":"FAILED","error_code":"INNER_RECEIPT_NOT_JSON"}
  expected={"PASS":0,"PENDING":2,"FAILED":1}.get(result.get("status"),1)
  code=expected if child_exit==expected else 1
  if child_exit!=expected:result.update({"status":"FAILED","error_code":"INNER_STATUS_EXIT_MISMATCH"})
 except subprocess.TimeoutExpired:
  child_exit=None;code=1
  result={"status":"FAILED","error_code":"INNER_TIMEOUT_OUTCOME_UNKNOWN","timeout_seconds":240}
 receipt={"phase":args.phase,"source_sha256":EXPECTED_SHA,"child_exit_code":child_exit,"wrapper_exit_code":code,"inner":result,"finished_utc":datetime.datetime.now(datetime.timezone.utc).isoformat()}
 path=BASE/("provider-wrapper-"+datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")+"-"+args.phase+".json")
 temp=path.with_suffix(".tmp")
 with temp.open("xb") as stream:
  stream.write((json.dumps(receipt,indent=2,sort_keys=True)+"\n").encode());stream.flush();os.fsync(stream.fileno())
 os.replace(temp,path)
 print(json.dumps(receipt,sort_keys=True))
 return code
if __name__=="__main__":sys.exit(main())
