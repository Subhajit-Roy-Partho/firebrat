"""Loopback-only preview harness using the real Firebrat API.

Copies of test books are provided via --output. Heavy conversion workers are
intentionally disabled: this verifies API/upload/queue UI, not server synthesis.
Production auth is unchanged. Optional fixture auth accepts one public test token
only in this explicitly launched loopback test process.
"""
import argparse,pathlib,sys
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--output',required=True);p.add_argument('--port',type=int,default=8765);p.add_argument('--fixture-auth',action='store_true');args=p.parse_args()
repo=pathlib.Path(__file__).resolve().parents[3];sys.path.insert(0,str(repo/'backend'))
from server import config,job_runner,auth
config.OUTPUT_DIR=str(pathlib.Path(args.output).resolve());config.UPLOAD_DIR=str(pathlib.Path(args.output).resolve().parent/'uploads');config.JOBS_DB_PATH=str(pathlib.Path(args.output).resolve().parent/'jobs.sqlite3')
job_runner.ensure_workers_started=lambda:None
job_runner.resume_orphaned_jobs=lambda:None
job_runner.enqueue=lambda *a,**k:None
from server.main import app
if args.fixture_auth:
    from fastapi import Header,HTTPException
    def fixture_user(authorization:str|None=Header(default=None)):
        if authorization!='Bearer firebrat-simulator-test-token':raise HTTPException(401,'sign-in required')
        return {'uid':'simulator-fixture','email':'test@example.invalid'}
    app.dependency_overrides[auth.require_user]=fixture_user
import uvicorn
uvicorn.run(app,host='127.0.0.1',port=args.port)
