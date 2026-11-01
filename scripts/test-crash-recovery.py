#!/usr/bin/env python3
"""SIGKILL only disposable LightNote processes; verify replay and original preservation."""
import json
import os
import pathlib
import selectors
import signal
import subprocess
import sys
import tempfile

binary = sys.argv[1] if len(sys.argv)>1 else "/Applications/LightNote.app/Contents/MacOS/LightNote"
for mode in ("--kill-before-save", "--kill-during-save", "--kill-after-temp-write", "--kill-after-save", "--external-conflict", "--kill-after-conflict", "--normal-close"):
    with tempfile.TemporaryDirectory(prefix="LightNote-crash-test-") as path:
        root=pathlib.Path(path)
        env={**os.environ,"LIGHTNOTE_TEST_DIRECTORY":path}
        args=[binary,"--self-test","--recovery-worker",mode]
        with (root/"worker.log").open("w+") as errors:
            process=subprocess.Popen(args,stdout=subprocess.PIPE,stderr=errors,env=env)
            try:
                if mode=="--normal-close":
                    output=process.communicate(timeout=25)[0]
                    assert process.returncode==0, errors.read()
                else:
                    selector=selectors.DefaultSelector(); selector.register(process.stdout,selectors.EVENT_READ)
                    assert selector.select(timeout=25), "Worker did not reach crash checkpoint"
                    line=process.stdout.readline(); selector.close()
                    assert line==b"READY_TO_KILL\n", (line,process.poll())
                    source=root/"lesson.lightnote"
                    if mode=="--external-conflict":
                        foreign=json.loads(source.read_text()); foreign["strokes"][0]["samples"][0]["x"]=54321
                        source.write_text(json.dumps(foreign))
                    original=source.read_bytes() if source.exists() else None
                    os.kill(process.pid,signal.SIGKILL); process.wait(timeout=5)
                    assert process.returncode==-signal.SIGKILL
            finally:
                if process.poll() is None: process.kill(); process.wait()
            recovered=subprocess.run([binary,"--self-test","--recover-only"],env=env,capture_output=True,text=True,timeout=25)
            assert recovered.returncode==0, recovered.stderr
            report=json.loads(recovered.stdout)
            assert not report["unreadable"], report
            expected=json.loads((root/"expected.json").read_text())
            if mode=="--kill-after-conflict":
                assert report["recovered"]==[], "Saved overwrite was recovered twice"
                assert json.loads((root/"lesson.lightnote").read_text())==expected
                assert (root/"lesson.lightnote").read_bytes()==original
            elif mode=="--normal-close":
                assert report["recovered"]==[], report
                assert json.loads((root/"lesson.lightnote").read_text())==expected
            else:
                assert len(report["recovered"])==1, report
                assert json.loads(pathlib.Path(report["recovered"][0]).read_text())==expected, "Recovered content differs"
                if original is not None: assert (root/"lesson.lightnote").read_bytes()==original, "Recovery overwrote original"
            retry=subprocess.run([binary,"--self-test","--recover-only"],env=env,capture_output=True,text=True,timeout=25)
            assert retry.returncode==0 and json.loads(retry.stdout)["recovered"]==[], "Recovery duplicated on restart"
            print("PASS:",mode,flush=True)
