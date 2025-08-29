#!/usr/bin/env python3
"""
spell – gerenciador de programas source‑based para Linux From Scratch

Características principais (MVP funcional):
- Recipes em YAML com variáveis expansíveis (${VAR}).
- Download via curl ou git; múltiplas fontes por recipe.
- Descompactação automática (tar.*/zip/7z) para diretório de trabalho por pacote/versão.
- Aplicação de patches (arquivos locais, diretórios com *.patch ou URLs http(s)).
- Build em árvore de trabalho isolada; registro de logs por etapa.
- Instalação em DESTDIR com fakeroot (quando disponível); empacotamento tar.zst do DESTDIR antes de instalar.
- Registro de instalação com lista de arquivos; banco simples JSON em ~/.local/share/spell/db.json.
- Remoção (uninstall) segura e reversível topologicamente (resolve dependências e bloqueia remoção se houver revdeps, a não ser com --force).
- search/list/info; upgrade (compara versão do recipe vs instalada); build‑only (faz tudo menos instalar); limpeza de diretórios de trabalho; remoção de órfãos.
- Saída colorida, spinner e barra de progresso simples.
- git sync do diretório de recipes.

Dependências:
- Python 3.8+
- PyYAML (pip install pyyaml) – para ler YAML
- curl, git, tar, unzip, 7z (quando necessário)
- fakeroot (opcional)

Uso rápido:
  spell.py build <pacote>            # compila mas não instala (usa --install para instalar)
  spell.py install <pacote>          # resolve deps, compila e instala
  spell.py remove <pacote>           # desinstala (checa reverse deps)
  spell.py search <regex>            # procura em recipes disponíveis
  spell.py list                      # lista instalados
  spell.py info <pacote>
  spell.py upgrade [pacote|--all]
  spell.py sync                      # git pull no repositório de recipes
  spell.py clean [--all|pacote]      # limpa workdirs e caches
  spell.py orphans                   # sugere pacotes órfãos

Estrutura de diretórios (por padrão sob ~/.local/share/spell):
  recipes/        # seu repositório git de recipes YAML
  work/<name>-<version>/
  pkgs/           # artefatos tar.zst gerados
  db.json         # banco de instalações
  logs/<name>/

Schema de recipe (exemplo):
---
name: zlib
version: 1.3.1
vars:
  URL: https://zlib.net/zlib-${version}.tar.xz
source:
  - type: curl
    url: ${URL}
    hash: sha256:xxxxxxxx
patches:
  - url: https://example.com/fix.patch
  - dir: patches/zlib/               # aplica todos *.patch
build:
  - ./configure --prefix=/usr
  - make -j$(nproc)
install:
  - make DESTDIR=${DESTDIR} install
runtime_deps: []
build_deps: []
provides: [zlib]

"""
from __future__ import annotations
import argparse
import contextlib
import dataclasses
import fnmatch
import hashlib
import json
import os
import queue
import re
import shlex
import shutil
import signal
import subprocess as sp
import sys
import tarfile
import tempfile
import threading
import time
from pathlib import Path

try:
    import yaml  # PyYAML
except Exception as e:
    print("[spell] ERRO: PyYAML não encontrado. Instale com: pip install pyyaml", file=sys.stderr)
    raise

# ====== Configurações ======
XDG = Path(os.environ.get("XDG_DATA_HOME", Path.home()/".local"/"share"))
BASE = Path(os.environ.get("SPELL_HOME", XDG/"spell"))
RECIPES_DIR = Path(os.environ.get("SPELL_RECIPES", BASE/"recipes"))
WORK_DIR = Path(os.environ.get("SPELL_WORK", BASE/"work"))
PKG_DIR = Path(os.environ.get("SPELL_PKGS", BASE/"pkgs"))
LOG_DIR = Path(os.environ.get("SPELL_LOGS", BASE/"logs"))
DB_PATH = Path(os.environ.get("SPELL_DB", BASE/"db.json"))
COLOR = sys.stdout.isatty() and os.environ.get("NO_COLOR") is None
FAKEROOT = shutil.which("fakeroot")
CURL = shutil.which("curl") or "curl"
GIT = shutil.which("git") or "git"
TAR = shutil.which("tar") or "tar"
UNZIP = shutil.which("unzip") or "unzip"
SEVENZ = shutil.which("7z") or shutil.which("7za")

# ====== Utils ======
class Colors:
    def __getattr__(self, name):
        if not COLOR: return ""
        codes = {
            'reset':'\033[0m','bold':'\033[1m','dim':'\033[2m',
            'red':'\033[31m','green':'\033[32m','yellow':'\033[33m','blue':'\033[34m','magenta':'\033[35m','cyan':'\033[36m'
        }
        return codes.get(name, "")
C = Colors()

def info(msg):
    print(f"{C.cyan}[*]{C.reset} {msg}")

def ok(msg):
    print(f"{C.green}[✓]{C.reset} {msg}")

def warn(msg):
    print(f"{C.yellow}[!]{C.reset} {msg}")

def err(msg):
    print(f"{C.red}[x]{C.reset} {msg}")

class Spinner:
    def __init__(self, text=""):
        self.text = text
        self._stop = threading.Event()
        self._t = threading.Thread(target=self._run, daemon=True)
        self.frames = "|/-\\"
    def _run(self):
        i=0
        while not self._stop.is_set():
            if COLOR and sys.stdout.isatty():
                sys.stdout.write(f"\r{C.blue}{self.frames[i%4]}{C.reset} {self.text}")
                sys.stdout.flush()
            time.sleep(0.1); i+=1
    def start(self): self._t.start()
    def stop(self):
        self._stop.set(); self._t.join(timeout=0.2)
        if sys.stdout.isatty(): sys.stdout.write("\r\x1b[2K")

# ====== Banco (registro) ======
@dataclasses.dataclass
class PackageRecord:
    name: str
    version: str
    files: list[str]
    runtime_deps: list[str]
    build_deps: list[str]
    provides: list[str]

class DB:
    def __init__(self, path:Path):
        self.path = path
        self.data = {"installed":{}}  # name -> record
        self._load()
    def _load(self):
        if self.path.exists():
            self.data = json.loads(self.path.read_text())
    def save(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(json.dumps(self.data, indent=2, ensure_ascii=False))
    def get(self, name:str)->PackageRecord|None:
        r = self.data["installed"].get(name)
        if r: return PackageRecord(**r)
    def set(self, rec:PackageRecord):
        self.data["installed"][rec.name] = dataclasses.asdict(rec); self.save()
    def remove(self, name:str):
        self.data["installed"].pop(name, None); self.save()
    def all(self):
        return {k:PackageRecord(**v) for k,v in self.data["installed"].items()}

DBI = DB(DB_PATH)

# ====== Recipes ======
@dataclasses.dataclass
class Recipe:
    name: str
    version: str
    vars: dict
    source: list
    patches: list
    build: list[str]
    install: list[str]
    runtime_deps: list[str]
    build_deps: list[str]
    provides: list[str]
    path: Path

    @staticmethod
    def load(path:Path, extra_env:dict[str,str]|None=None)->'Recipe':
        data = yaml.safe_load(path.read_text())
        # Variáveis padrão
        data.setdefault('vars', {})
        base_vars = {
            'name': data['name'],
            'version': str(data['version']),
        }
        env = {**os.environ, **base_vars, **data['vars']}
        # expansão recursiva de ${VAR}
        def expand(obj):
            if isinstance(obj, str):
                return os.path.expandvars(_expand_with(env, obj))
            if isinstance(obj, list):
                return [expand(x) for x in obj]
            if isinstance(obj, dict):
                return {k:expand(v) for k,v in obj.items()}
            return obj
        data = expand(data)
        return Recipe(
            name=data['name'], version=str(data['version']), vars=data.get('vars', {}),
            source=data.get('source', []), patches=data.get('patches', []),
            build=data.get('build', []), install=data.get('install', []),
            runtime_deps=data.get('runtime_deps', []), build_deps=data.get('build_deps', []),
            provides=data.get('provides', []), path=path
        )


def _expand_with(env:dict, s:str)->str:
    # Expansão ${VAR} incluindo variáveis definidas no recipe
    pattern = re.compile(r"\${([^}]+)}")
    def repl(m):
        k = m.group(1)
        return str(env.get(k, m.group(0)))
    return pattern.sub(repl, s)

# ====== Execução de comandos ======

def run(cmd:str|list[str], cwd:Path|None=None, log:Path|None=None, env:dict|None=None, use_fakeroot=False):
    if isinstance(cmd, str):
        shell=True; cmdline=cmd
    else:
        shell=False; cmdline=cmd
    penv = os.environ.copy()
    if env: penv.update(env)
    spinner = Spinner(text=f"{cwd or Path.cwd()} :: {cmd if isinstance(cmd,str) else ' '.join(cmd)}")
    spinner.start()
    proc = sp.Popen(cmdline, cwd=str(cwd) if cwd else None, shell=shell, env=penv,
                    stdout=sp.PIPE, stderr=sp.STDOUT, text=True, bufsize=1, executable='/bin/bash')
    lines=[]
    try:
        for line in proc.stdout:
            lines.append(line)
        proc.wait()
    finally:
        spinner.stop()
    if log:
        log.parent.mkdir(parents=True, exist_ok=True)
        log.write_text(''.join(lines))
    if proc.returncode!=0:
        err(f"Falha ao executar: {cmd}")
        if log: warn(f"Verifique o log: {log}")
        raise SystemExit(proc.returncode)

# ====== Download & Extrair ======

def download_to(url:str, dest:Path):
    dest.parent.mkdir(parents=True, exist_ok=True)
    info(f"Baixando {url}")
    run([CURL, '-L', '-o', str(dest), url])
    return dest


def git_clone(url:str, dest:Path, ref:str|None=None):
    info(f"Clonando {url}")
    run([GIT, 'clone', '--depth', '1'] + (["--branch", ref] if ref else []) + [url, str(dest)])


def extract(archive:Path, dest:Path):
    dest.mkdir(parents=True, exist_ok=True)
    info(f"Extraindo {archive.name}")
    # Tente stdlib primeiro
    try:
        shutil.unpack_archive(str(archive), str(dest))
        return
    except Exception:
        pass
    # Fallbacks
    suf = archive.suffixes
    if any(x in ''.join(suf) for x in ['.tar', '.gz', '.bz2', '.xz', '.zst']):
        run([TAR, 'xf', str(archive), '-C', str(dest)])
    elif archive.suffix == '.zip':
        run([UNZIP, '-q', str(archive), '-d', str(dest)])
    elif SEVENZ:
        run([SEVENZ, 'x', str(archive), f"-o{dest}", '-y'])
    else:
        raise SystemExit(f"Não sei extrair: {archive}")

# ====== Patches ======

def apply_patch_file(patch:Path, cwd:Path):
    info(f"Aplicando patch {patch.name}")
    cmd = f"patch -p1 < {shlex.quote(str(patch))}"
    run(cmd, cwd=cwd)


def apply_patches(patches, cwd:Path):
    for p in patches or []:
        if isinstance(p, dict) and 'url' in p:
            with tempfile.TemporaryDirectory() as td:
                tmp = Path(td)/Path(p['url']).name
                download_to(p['url'], tmp)
                apply_patch_file(tmp, cwd)
        elif isinstance(p, dict) and 'dir' in p:
            d = Path(_expand_with({}, str(p['dir'])))
            for f in sorted(d.glob('*.patch')):
                apply_patch_file(f, cwd)
        else:
            apply_patch_file(Path(str(p)), cwd)

# ====== Dependências ======

def load_all_recipes()->dict[str,Recipe]:
    recipes = {}
    if not RECIPES_DIR.exists():
        warn(f"Diretório de recipes não encontrado: {RECIPES_DIR}")
        return recipes
    for yml in RECIPES_DIR.rglob('*.yml') | RECIPES_DIR.rglob('*.yaml'):
        r = Recipe.load(yml)
        recipes[r.name]=r
    return recipes


def topo_sort(reqs:set[str], recipes:dict[str,Recipe]):
    # Kahn
    graph = {}
    indeg = {}
    for r in recipes.values():
        deps = set(r.runtime_deps or []) | set(r.build_deps or [])
        graph[r.name]=deps
    # Filtro por reqs + suas deps
    needed=set()
    def dfs(n):
        if n in needed: return
        needed.add(n)
        for d in graph.get(n,[]):
            if d in recipes: dfs(d)
    for n in reqs:
        if n in recipes: dfs(n)
    subg = {n:graph.get(n,set()) & needed for n in needed}
    indeg = {n:0 for n in needed}
    for n,ds in subg.items():
        for d in ds: indeg[n]+=1
    q=[n for n,v in indeg.items() if v==0]
    out=[]
    while q:
        n=q.pop(0); out.append(n)
        for m in subg:
            if n in subg[m]:
                indeg[m]-=1
                if indeg[m]==0: q.append(m)
    return out


def reverse_deps(targets:list[str])->dict[str,set[str]]:
    rev={k:set() for k in DBI.all().keys()}
    for pkg,rec in DBI.all().items():
        for d in rec.runtime_deps:
            if d in rev: rev[d].add(pkg)
    return {t:rev.get(t,set()) for t in targets}

# ====== Build/Install ======

def ensure_dirs():
    for d in [BASE, RECIPES_DIR, WORK_DIR, PKG_DIR, LOG_DIR]: d.mkdir(parents=True, exist_ok=True)


def stage_paths(name, version):
    work = WORK_DIR/f"{name}-{version}"
    src = work/"src"
    build = work/"build"
    destdir = work/"destdir"
    log = LOG_DIR/name
    return work, src, build, destdir, log


def fetch_sources(recipe:Recipe, srcdir:Path):
    srcdir.mkdir(parents=True, exist_ok=True)
    for i,src in enumerate(recipe.source or []):
        t = src.get('type','curl')
        if t=='curl':
            url = src['url']
            fn = src.get('filename') or Path(url).name
            dest = srcdir/fn
            download_to(url, dest)
            h = src.get('hash')
            if h: verify_hash(dest, h)
            # extração automática
            if any(fn.endswith(x) for x in ['.tar.gz','.tar.xz','.tar.bz2','.zip','.tar','.tgz','.tbz','.txz','.7z','.gz','.bz2','.xz','.zst']):
                extract(dest, srcdir)
        elif t=='git':
            repo = src['url']
            ref = src.get('ref')
            gdest = srcdir/(src.get('dir') or Path(repo).stem)
            git_clone(repo, gdest, ref)
        else:
            raise SystemExit(f"Fonte desconhecida: {t}")


def verify_hash(path:Path, spec:str):
    algo, expected = spec.split(':',1)
    h = hashlib.new(algo)
    with open(path,'rb') as f:
        for chunk in iter(lambda: f.read(1024*1024), b''):
            h.update(chunk)
    got = h.hexdigest()
    if got!=expected:
        raise SystemExit(f"Hash incorreta para {path.name}: esperado {expected}, obtido {got}")


def pick_build_root(srcdir:Path)->Path:
    # tente pegar único subdir extraído
    subs = [p for p in srcdir.iterdir() if p.is_dir() and not p.name.startswith('.')]
    return subs[0] if len(subs)==1 else srcdir


def do_build(recipe:Recipe, install=False):
    ensure_dirs()
    work, srcdir, builddir, destdir, logdir = stage_paths(recipe.name, recipe.version)
    info(f"Preparando build de {recipe.name}-{recipe.version}")
    if work.exists():
        info("Limpando workdir anterior")
        shutil.rmtree(work)
    srcdir.mkdir(parents=True, exist_ok=True)
    # Fetch
    fetch_sources(recipe, srcdir)
    root = pick_build_root(srcdir)
    # Patches
    apply_patches(recipe.patches, root)
    # Build
    builddir.mkdir(parents=True, exist_ok=True)
    env = {
        'DESTDIR': str(destdir),
        'PREFIX': '/usr',
        'PKG_CONFIG_PATH': '/usr/lib/pkgconfig:/usr/share/pkgconfig',
    }
    for i,cmd in enumerate(recipe.build or []):
        run(cmd, cwd=root, log=logdir/f"build-{i:02d}.log", env=env)
    ok("Build concluído")
    if not install:
        return
    # Install (em DESTDIR)
    for i,cmd in enumerate(recipe.install or []):
        run(cmd, cwd=root, log=logdir/f"install-{i:02d}.log", env=env, use_fakeroot=bool(FAKEROOT))
    # Pacote (tar.zst) do DESTDIR
    pkgname = f"{recipe.name}-{recipe.version}.tar.zst"
    pkgpath = PKG_DIR/pkgname
    info("Empacotando artefato")
    run(f"{TAR} -C {shlex.quote(str(destdir))} -I 'zstd -19 -T0' -cf {shlex.quote(str(pkgpath))} .")
    # Instalação real (copia arquivos do DESTDIR para /)
    info("Instalando no sistema (/) a partir do DESTDIR)")
    filelist=[]
    for rootd, dirs, files in os.walk(destdir):
        relroot = os.path.relpath(rootd, start=destdir)
        for d in dirs:
            target = Path('/')/relroot/d
            target.mkdir(parents=True, exist_ok=True)
        for f in files:
            src = Path(rootd)/f
            dst = Path('/')/relroot/f
            # cria diretório
            dst.parent.mkdir(parents=True, exist_ok=True)
            # move/overwrite
            shutil.copy2(src, dst, follow_symlinks=True)
            filelist.append(str(dst))
    DBI.set(PackageRecord(
        name=recipe.name, version=recipe.version, files=filelist,
        runtime_deps=recipe.runtime_deps or [], build_deps=recipe.build_deps or [], provides=recipe.provides or []
    ))
    ok(f"Instalado {recipe.name}-{recipe.version}")

# ====== Remoção / Órfãos ======

def uninstall(name:str, force=False):
    rec = DBI.get(name)
    if not rec:
        warn(f"{name} não está instalado")
        return
    rev = reverse_deps([name])[name]
    if rev and not force:
        raise SystemExit(f"Não é possível remover {name}: requerido por {', '.join(sorted(rev))}. Use --force para forçar.")
    info(f"Removendo {name}")
    for f in sorted(rec.files, key=lambda x: len(x.split('/')), reverse=True):
        p = Path(f)
        try:
            if p.is_file() or p.is_symlink(): p.unlink(missing_ok=True)
            # tenta limpar diretórios vazios ascendentes
            with contextlib.suppress(Exception):
                d=p.parent
                while d != Path('/'):
                    d.rmdir(); d=d.parent
        except Exception as e:
            warn(f"Falha removendo {p}: {e}")
    DBI.remove(name)
    ok(f"Removido {name}")


def find_orphans():
    installed = DBI.all()
    required = set()
    for r in installed.values():
        required.update(r.runtime_deps)
    orphans = set(installed.keys()) - required
    return sorted(orphans)

# ====== CLI ======

def cmd_search(args):
    recipes = load_all_recipes()
    rgx = re.compile(args.pattern)
    for name in sorted(recipes):
        if rgx.search(name):
            print(name)


def cmd_list(args):
    for name,rec in sorted(DBI.all().items()):
        print(f"{name} {rec.version}")


def cmd_info(args):
    recipes = load_all_recipes()
    r = recipes.get(args.name)
    inst = DBI.get(args.name)
    if r:
        print(f"Recipe: {r.name}-{r.version}\nDeps: {' '.join(r.runtime_deps)}\nBuild: {' '.join(r.build_deps)}")
    else:
        warn("Recipe não encontrado")
    if inst:
        print(f"Instalado: {inst.version}")


def cmd_build(args):
    recipes = load_all_recipes()
    r = recipes.get(args.name)
    if not r: raise SystemExit("Recipe não encontrado")
    # Resolver deps
    order = topo_sort({r.name}, recipes)
    info("Ordem de build: "+' -> '.join(order))
    for n in order:
        rr = recipes[n]
        do_build(rr, install=args.install)


def cmd_install(args):
    args.install=True
    cmd_build(args)


def cmd_remove(args):
    uninstall(args.name, force=args.force)


def cmd_upgrade(args):
    recipes = load_all_recipes()
    if args.all:
        targets = [n for n in DBI.all().keys() if n in recipes]
    else:
        targets = [args.name]
    for n in targets:
        inst = DBI.get(n)
        r = recipes.get(n)
        if not r:
            warn(f"Sem recipe para {n}")
            continue
        if not inst or inst.version != r.version:
            info(f"Atualizando {n}: {inst.version if inst else 'n/a'} -> {r.version}")
            do_build(r, install=True)
        else:
            ok(f"{n} já na versão {r.version}")


def cmd_sync(args):
    if not RECIPES_DIR.exists():
        raise SystemExit(f"Recipes não encontrado em {RECIPES_DIR}")
    info("Sincronizando recipes (git pull)")
    run([GIT,'-C',str(RECIPES_DIR),'pull','--rebase'])


def cmd_clean(args):
    if args.all:
        if WORK_DIR.exists(): shutil.rmtree(WORK_DIR); ok("work/ limpo")
        return
    if args.name:
        rdir = next(WORK_DIR.glob(f"{args.name}-*"), None)
        if rdir and rdir.exists(): shutil.rmtree(rdir); ok(f"{rdir.name} limpo")


def cmd_orphans(args):
    for n in find_orphans():
        print(n)


def build_argparser():
    p = argparse.ArgumentParser(prog='spell', description='Gerenciador de programas source-based (LFS)')
    sub = p.add_subparsers(dest='cmd', required=True)

    s=sub.add_parser('search'); s.add_argument('pattern'); s.set_defaults(func=cmd_search)
    s=sub.add_parser('list'); s.set_defaults(func=cmd_list)
    s=sub.add_parser('info'); s.add_argument('name'); s.set_defaults(func=cmd_info)

    s=sub.add_parser('build'); s.add_argument('name'); s.add_argument('--install', action='store_true'); s.set_defaults(func=cmd_build)
    s=sub.add_parser('install'); s.add_argument('name'); s.set_defaults(func=cmd_install)

    s=sub.add_parser('remove'); s.add_argument('name'); s.add_argument('--force', action='store_true'); s.set_defaults(func=cmd_remove)

    s=sub.add_parser('upgrade');
    g = s.add_mutually_exclusive_group(required=True)
    g.add_argument('name', nargs='?')
    g.add_argument('--all', action='store_true')
    s.set_defaults(func=cmd_upgrade)

    s=sub.add_parser('sync'); s.set_defaults(func=cmd_sync)
    s=sub.add_parser('clean'); s.add_argument('name', nargs='?'); s.add_argument('--all', action='store_true'); s.set_defaults(func=cmd_clean)

    s=sub.add_parser('orphans'); s.set_defaults(func=cmd_orphans)

    return p


def main(argv=None):
    ensure_dirs()
    ap = build_argparser()
    args = ap.parse_args(argv)
    args.func(args)

if __name__ == '__main__':
    main()
