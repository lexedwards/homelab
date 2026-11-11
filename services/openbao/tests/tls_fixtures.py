from pathlib import Path
import shutil
import subprocess


def openssl(*args):
    return subprocess.run(["openssl", *map(str, args)], check=True, capture_output=True, text=True, timeout=15)


def create_ca(root):
    root = Path(root)
    root.mkdir(parents=True, exist_ok=True)
    openssl("req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes",
            "-keyout", root / "ca.key", "-out", root / "ca.pem", "-days", "365",
            "-subj", "/CN=Disposable OpenBao test CA", "-addext", "basicConstraints=critical,CA:TRUE",
            "-addext", "keyUsage=critical,keyCertSign,cRLSign")
    (root / "ca.key").chmod(0o600)
    return root


def issue_certificate(root, ca, hostname="localhost", days=30):
    root = Path(root)
    root.mkdir(parents=True, exist_ok=True)
    openssl("req", "-new", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes",
            "-keyout", root / "privkey.pem", "-out", root / "request.pem", "-subj", f"/CN={hostname}")
    extensions = root / "extensions.cnf"
    extensions.write_text(f"subjectAltName=DNS:{hostname}\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\nkeyUsage=critical,digitalSignature\nauthorityKeyIdentifier=keyid,issuer\nsubjectKeyIdentifier=hash\n")
    openssl("x509", "-req", "-in", root / "request.pem", "-CA", ca / "ca.pem", "-CAkey", ca / "ca.key",
            "-CAcreateserial", "-out", root / "cert.pem", "-days", str(days), "-extfile", extensions)
    shutil.copyfile(ca / "ca.pem", root / "chain.pem")
    (root / "fullchain.pem").write_bytes((root / "cert.pem").read_bytes() + (root / "chain.pem").read_bytes())
    (root / "privkey.pem").chmod(0o600)
    return root
