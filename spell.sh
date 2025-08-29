#!/usr/bin/env bash
# spell — um gerenciador de programas simples para LFS/ports
# Licença: MIT
# Requisitos: bash 4+, coreutils, curl, git, tar, xz, unzip, gzip, bzip2, zstd, patch, sha256sum,
#             rsync, fakeroot (opcional mas recomendado), jq (opcional p/ saída)
# Testado: Linux base, sem systemd dependente. Use por sua conta e risco.

set -euo pipefail
IFS=$'\n\t'

VERSION="0.2.0"

########################################
# Configuração
########################################
: "${SPELL_HOME:=${XDG_DATA_HOME:-$HOME/.local/share}/spell}"     # estado e cache
: "${SPELL_ETC:=${XDG_CONFIG_HOME:-$HOME/.config}/spell}"         # config & fórmulas
: "${SPELL_REPO:=$SPELL_HOME/repo}"                               # repositório git (estado)
: "${SPELL_FORMULAE:=$SPELL_ETC/formulae}"                        # diretório de pacotes *.spell
: "${SPELL_WORK:=$SPELL_HOME/work}"                               # diretório de trabalho (build/DESTDIR)
: "${SPELL_SRC:=$SPELL_HOME/src}"                                 # downloads originais
: "${SPELL_BINREPO:=$SPELL_HOME/binrepo}"                         # pacotes binários construídos (tar)
: "${SPELL_LOGS:=$SPELL_HOME/logs}"                               # logs de build/install
: "${SPELL_DB:=$SPELL_HOME/db}"                                   # base instalada (metadados + files)
: "${SPELL_HOOKS:=$SPELL_ETC/hooks}"                              # hooks (pre-install, post-remove, etc)
: "${SPELL_COLOR:=1}"
: "${SPELL_SPINNER:=1}"

mkdir -p "$SPELL_HOME" "$SPELL_ETC" "$SPELL_REPO" "$SPELL_FORMULAE" \
         "$SPELL_WORK" "$SPELL_SRC" "$SPELL_BINREPO" "$SPELL_LOGS" "$SPELL_DB" "$SPELL_HOOKS"

# Lock global para evitar concorrência
LOCKFILE="$SPELL_HOME/.lock"
exec 9>"$LOCKFILE"
flock -n 9 || { echo "Outra instância do spell está rodando (lock: $LOCKFILE)" >&2; exit 1; }

########################################
# Utilidades: cores, spinner, log
########################################
if [[ ${SPELL_COLOR} -eq 1 && -t 1 ]]; then
  C_RESET='\033[0m'; C_BOLD='\033[1m'; C_DIM='\033[2m'
  C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_BLUE='\033[34m'
else
  C_RESET=''; C_BOLD=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''
fi

msg() { printf "%b\n" "${C_BOLD}$*${C_RESET}"; }
info() { printf "%b\n" "${C_BLUE}==>${C_RESET} $*"; }
ok()   { printf "%b\n" "${C_GREEN}✔${C_RESET} $*"; }
warn() { printf "%b\n" "${C_YELLOW}⚠${C_RESET} $*"; }
err()  { printf "%b\n" "${C_RED}✖${C_RESET} $*" 1>&2; }

SP_PID=""
start_spinner() {
  [[ ${SPELL_SPINNER} -eq 1 && -t 1 ]] || return 0
  local chars='⠋⠙⠚⠞⠖⠦⠴⠲⠳⠓'
  ( while :; do for ((i=0;i<${#chars};i++)); do printf "\r%s" "${chars:i:1}"; sleep 0.08; done; done ) &
  SP_PID=$!
}
stop_spinner() { [[ -n ${SP_PID} ]] && { kill "$SP_PID" >/dev/null 2>&1 || true; printf "\r \r"; SP_PID=""; }; }

logfile() { mkdir -p "$SPELL_LOGS/$1"; printf "%s/%s/%s.log" "$SPELL_LOGS" "$1" "$(date +%Y%m%d-%H%M%S)"; }

have() { command -v "$1" >/dev/null 2>&1; }

########################################
# Formato de fórmula (*.spell)
# Arquivo bash que define:
#   NAME, VERSION, RELEASE (opcional), URL (tarball) OU GIT (url,branch,commit)
#   SHA256 (tarball), DEPENDS=(...) opcional
#   PATCHES=( local/dir/*.patch | http(s):// | git:// ) opcional
#   BUILD() { ./configure --prefix=/usr; make; }  (obrigatório ou default)
#   INSTALL() { make DESTDIR="$DESTDIR" install; } (opcional; default faz isso)
#   STRIP_BINARIES=1 (padrão 1)
########################################

load_formula() {
  local name="$1"; local path="$SPELL_FORMULAE/$name.spell"
  [[ -f "$path" ]] || { err "Fórmula não encontrada: $name ($path)"; exit 1; }
  # shellcheck disable=SC1090
  source "$path"
  : "${NAME:?defina NAME na fórmula}"; : "${VERSION:?defina VERSION}"; : "${RELEASE:=1}"
  : "${DEPENDS:=()}"; : "${STRIP_BINARIES:=1}"
}

# Extrai um campo simples sem executar a fórmula (uso: formula_field pkg VERSION)
formula_field() {
  local name="$1" field="$2"; local path="$SPELL_FORMULAE/$name.spell"
  [[ -f "$path" ]] || return 1
  awk -v f="$field" '
    $1==f && $2=="=" {
      # linha tipo: FIELD=valor
      sub(/^[^=]+= */, "", $0); gsub(/^"|"$/, "", $0); print $0; exit
    }
    match($0, "^"f"=\"[^\"]*\"") {
      s=$0; sub(/^"f"=\"/, "", s); sub(/\".*/, "", s); print s; exit
    }
  ' "$path"
}

########################################
# Resolução de dependências (topo + reverse)
########################################

topo_order() {
  declare -A seen; declare -a order
  local visit
  visit() {
    local pkg="$1"
    [[ -n ${seen[$pkg]:-} ]] && { [[ ${seen[$pkg]} == done ]] || true; return 0; }
    seen[$pkg]=visiting
    load_formula "$pkg" >/dev/null 2>&1 || { err "Fórmula ausente: $pkg"; exit 1; }
    local d
    for d in "${DEPENDS[@]:-}"; do visit "$d"; done
    seen[$pkg]=done; order+=("$pkg")
  }
  local t
  for t in "$@"; do visit "$t"; done
  printf "%s\n" "${order[@]}"
}

reverse_topo_order() { mapfile -t _o < <(topo_order "$@"); tac <<<"${_o[*]}" | tr ' ' '\n'; }

########################################
# Download / verificação
########################################

fetch_source() {
  local name="$1"; load_formula "$name"
  mkdir -p "$SPELL_SRC/$NAME-$VERSION"
  if [[ -n ${URL:-} ]]; then
    local fname="$SPELL_SRC/$NAME-$VERSION/$(basename "$URL")"
    if [[ ! -f "$fname" ]]; then
      info "Baixando $URL"
      curl -L --fail -o "$fname" "$URL"
    else
      info "Usando cache: $fname"
    fi
    if [[ -n ${SHA256:-} ]]; then
      (cd "$(dirname "$fname")" && echo "$SHA256  $(basename "$fname")" | sha256sum -c -) \
        || { err "sha256 inválido para $fname"; exit 1; }
    fi
    echo "$fname"
  elif [[ -n ${GIT:-} ]]; then
    local dest="$SPELL_SRC/$NAME-$VERSION/git"
    if [[ ! -d "$dest/.git" ]]; then
      info "Clonando $GIT"
      git clone --depth=1 ${GIT_BRANCH:+-b "$GIT_BRANCH"} "$GIT" "$dest"
      [[ -n ${GIT_COMMIT:-} ]] && (cd "$dest" && git reset --hard "$GIT_COMMIT")
    else
      info "Atualizando git: $dest"
      (cd "$dest" && git fetch --all --tags && git reset --hard ${GIT_COMMIT:-origin/${GIT_BRANCH:-HEAD}})
    fi
    echo "$dest"
  else
    err "Defina URL ou GIT na fórmula $name"; exit 1
  fi
}

########################################
# Descompactação para diretório de trabalho
########################################

tar_supports_zstd() { tar --help 2>&1 | grep -q -- '--zstd'; }

unpack_to_workdir() {
  local name="$1"; load_formula "$name"
  local src; src=$(fetch_source "$name")
  local wdir="$SPELL_WORK/$NAME-$VERSION"
  rm -rf "$wdir"; mkdir -p "$wdir"
  info "Descompactando em $wdir"
  if [[ -d "$src/.git" ]]; then
    rsync -a --delete "$src/" "$wdir/"
  else
    case "$src" in
      *.tar.gz|*.tgz)   tar -C "$wdir" --strip-components=1 -xzf "$src";;
      *.tar.bz2|*.tbz2) tar -C "$wdir" --strip-components=1 -xjf "$src";;
      *.tar.xz)         tar -C "$wdir" --strip-components=1 -xJf "$src";;
      *.tar.zst|*.tar.zstd)
        if tar_supports_zstd; then tar -C "$wdir" --strip-components=1 --zstd -xf "$src"
        else unzstd -c "$src" | tar -C "$wdir" --strip-components=1 -xf -; fi ;;
      *.zip)
        unzip -q "$src" -d "$wdir"
        local first; first=$(find "$wdir" -mindepth 1 -maxdepth 1 -type d | head -n1 || true)
        [[ -n ${first:-} ]] && rsync -a "$first"/ "$wdir"/ && rm -rf "$first"
        ;;
      *.tar)            tar -C "$wdir" --strip-components=1 -xf "$src";;
      *) err "Formato não suportado: $src"; exit 1;;
    esac
  fi
  echo "$wdir"
}

########################################
# Patches (dir, http(s), git)
########################################
apply_patches() {
  local name="$1"; load_formula "$name"
  [[ -z ${PATCHES:+x} ]] && return 0
  local wdir="$SPELL_WORK/$NAME-$VERSION"; [[ -d "$wdir" ]] || wdir=$(unpack_to_workdir "$name")
  info "Aplicando patches"
  pushd "$wdir" >/dev/null
  local p
  for p in "${PATCHES[@]}"; do
    if [[ -d "$p" ]]; then
      for f in "$p"/*.patch; do [[ -e "$f" ]] || continue; info "patch < $(basename "$f")"; patch -p1 < "$f"; done
    elif [[ "$p" =~ ^https?:// ]]; then
      local tmp; tmp=$(mktemp); curl -L --fail -o "$tmp" "$p"; info "patch < $(basename "$p")"; patch -p1 < "$tmp"; rm -f "$tmp"
    elif [[ "$p" =~ ^git://|^https?://.*\.git$ ]]; then
      local tmpdir; tmpdir=$(mktemp -d); git clone --depth=1 "$p" "$tmpdir"
      for f in "$tmpdir"/*.patch; do [[ -e "$f" ]] || continue; info "patch < $(basename "$f")"; patch -p1 < "$f"; done
      rm -rf "$tmpdir"
    elif [[ -f "$p" ]]; then
      info "patch < $(basename "$p")"; patch -p1 < "$p"
    else
      warn "Ignorando origem de patch desconhecida: $p"
    fi
  done
  popd >/dev/null
}

########################################
# Build, pacote binário e instalação com DESTDIR/fakeroot
########################################

build_package() {
  local name="$1"; load_formula "$name"
  local wdir; wdir=$(unpack_to_workdir "$name")
  apply_patches "$name"
  local log; log=$(logfile "$NAME")
  local DESTDIR="$wdir/_destdir"; export DESTDIR
  rm -rf "$DESTDIR"; mkdir -p "$DESTDIR"
  pushd "$wdir" >/dev/null
  info "Compilando $NAME-$VERSION (log: $log)"
  start_spinner
  {
    if declare -F BUILD >/dev/null; then
      BUILD
    else
      ./configure --prefix=/usr
      make -j"${MAKEFLAGS_JOBS:-$(nproc 2>/dev/null || echo 1)}"
    fi
    if declare -F INSTALL >/dev/null; then
      INSTALL
    else
      make DESTDIR="$DESTDIR" install
    fi
    if [[ ${STRIP_BINARIES} -eq 1 ]] && have strip; then
      find "$DESTDIR" -type f -perm -111 -exec strip --strip-unneeded {} + 2>/dev/null || true
    fi
  } &>"$log"
  stop_spinner
  ok "Build concluído: $NAME-$VERSION"
  popd >/dev/null
  echo "$DESTDIR"
}

make_binary() {
  local name="$1"; load_formula "$name"
  local DESTDIR; DESTDIR=$(build_package "$name")
  local out="$SPELL_BINREPO/${NAME}-${VERSION}-${RELEASE}.tar.zst"
  info "Gerando binário: $(basename "$out")"
  if tar_supports_zstd; then
    (cd "$DESTDIR" && tar --zstd -cf "$out" .)
  else
    (cd "$DESTDIR" && tar -cf - . | zstd -T0 -q -o "$out")
  fi
  # manifest
  if tar_supports_zstd; then
    tar -tf "$out" | sort > "$SPELL_BINREPO/${NAME}-${VERSION}-${RELEASE}.manifest"
  else
    zstd -d -c "$out" | tar -tf - | sort > "$SPELL_BINREPO/${NAME}-${VERSION}-${RELEASE}.manifest"
  fi
  ok "Binário criado em $out"
  echo "$out"
}

run_hook() {
  local stage="$1"; local name="$2"
  local hook="$SPELL_HOOKS/$stage"
  if [[ -x "$hook" ]]; then
    info "Hook: $stage"
    NAME="$name" SPELL_HOME="$SPELL_HOME" SPELL_DB="$SPELL_DB" "$hook" || warn "Hook $stage falhou"
  fi
}

_install_tree_into_root() {
  # copia de tmpdir para /
  local from="$1"
  if have fakeroot; then
    fakeroot rsync -aH --delete-after "$from"/ /
  else
    rsync -aH --delete-after "$from"/ /
  fi
}

install_binary() {
  local tarball="$1"; local name ver rel
  name=$(basename "$tarball" | sed -E 's/^([^/]+)-([^-]+)-([0-9]+)\.tar\.(zst|xz|gz)$/\1/')
  ver=$(basename "$tarball" | sed -E 's/^([^/]+)-([^-]+)-([0-9]+)\.tar\.(zst|xz|gz)$/\2/')
  rel=$(basename "$tarball" | sed -E 's/^([^/]+)-([^-]+)-([0-9]+)\.tar\.(zst|xz|gz)$/\3/')
  [[ -n "$name" && -n "$ver" && -n "$rel" ]] || { err "Nome de pacote inválido: $(basename "$tarball")"; exit 1; }
  local log; log=$(logfile "$name")
  info "Instalando $name-$ver-$rel (log: $log)"
  start_spinner
  {
    run_hook pre-install "$name" || true

    local tmp; tmp=$(mktemp -d)
    case "$tarball" in
      *.tar.zst|*.tar.zstd)
        if tar_supports_zstd; then tar -C "$tmp" --zstd -xf "$tarball"
        else zstd -d -c "$tarball" | tar -C "$tmp" -xf -; fi ;;
      *.tar.xz) tar -C "$tmp" -xJf "$tarball";;
      *.tar.gz|*.tgz) tar -C "$tmp" -xzf "$tarball";;
      *.tar) tar -C "$tmp" -xf "$tarball";;
      *) err "Formato binário não suportado: $tarball"; exit 1;;
    esac

    _install_tree_into_root "$tmp"
    rm -rf "$tmp"

    mkdir -p "$SPELL_DB/$name"
    printf "%s\n" "$ver" > "$SPELL_DB/$name/version"
    printf "%s\n" "$rel" > "$SPELL_DB/$name/release"

    # gerar lista de arquivos instalados a partir do tar
    case "$tarball" in
      *.tar.zst|*.tar.zstd)
        if tar_supports_zstd; then
          tar -tf "$tarball" | sed 's#^#/#' > "$SPELL_DB/$name/files"
        else
          zstd -d -c "$tarball" | tar -tf - | sed 's#^#/#' > "$SPELL_DB/$name/files"
        fi ;;
      *) tar -tf "$tarball" | sed 's#^#/#' > "$SPELL_DB/$name/files" ;;
    esac

    date -u +%FT%TZ > "$SPELL_DB/$name/installed_at"
    run_hook post-install "$name" || true
  } &>"$log"
  stop_spinner
  ok "Instalado: $name-$ver (release $rel)"
}

install_from_source() {
  local name="$1"; local bin; bin=$(make_binary "$name"); install_binary "$bin"
}

########################################
# Remoção (desfazendo instalação)
########################################

remove_package() {
  local name="$1"
  [[ -d "$SPELL_DB/$name" ]] || { warn "$name não está instalado"; return 0; }
  run_hook pre-remove "$name" || true
  info "Removendo $name"
  # remover em ordem reversa; tentar limpar diretórios ascendentes
  tac "$SPELL_DB/$name/files" | while read -r f; do
    [[ -z "$f" ]] && continue
    if [[ -e "$f" || -L "$f" ]]; then
      rm -f "$f" 2>/dev/null || true
    fi
    # tentar remover diretórios vazios ascendentes
    local d; d=$(dirname "$f")
    for _ in {1..6}; do rmdir "$d" 2>/dev/null || true; d=$(dirname "$d"); done
  done
  rm -rf "$SPELL_DB/$name"
  run_hook post-remove "$name" || true
  ok "Removido $name"
}

########################################
# Sync do estado para repositório git
########################################

git_sync() {
  ( cd "$SPELL_REPO"
    git init -q
    mkdir -p db logs manifests
    rsync -a "$SPELL_DB/" db/ 2>/dev/null || true
    rsync -a "$SPELL_LOGS/" logs/ 2>/dev/null || true
    rsync -a "$SPELL_BINREPO/" manifests/ 2>/dev/null || true
    git add -A
    if ! git diff --cached --quiet; then
      git commit -m "spell sync $(date -u +%F_%T)" >/dev/null || true
      info "Commit criado em $SPELL_REPO"
    else
      info "Sem mudanças para commit"
    fi
  )
}

########################################
# Upgrade
########################################

upgrade_one() {
  local name="$1"; load_formula "$name"
  local current=""; [[ -f "$SPELL_DB/$name/version" ]] && current=$(<"$SPELL_DB/$name/version") || true
  if [[ "$current" == "$VERSION" ]]; then
    info "$name já está na versão $VERSION"; return 0
  fi
  info "Atualizando $name: $current -> $VERSION"
  install_from_source "$name"
}

########################################
# Busca / info / list
########################################

cmd_search() { local q="${1:-}"; ls -1 "$SPELL_FORMULAE"/*.spell 2>/dev/null | sed 's#.*/##;s/\.spell$//' | grep -i -- "$q" || true; }

cmd_info() {
  local name="$1"; load_formula "$name"
  echo "NAME: $NAME"
  echo "VERSION: $VERSION"
  echo "RELEASE: ${RELEASE:-1}"
  echo "DEPENDS: ${DEPENDS[*]:-}"
  [[ -n ${URL:-} ]] && echo "URL: $URL"
  [[ -n ${GIT:-} ]] && echo "GIT: $GIT ${GIT_BRANCH:+(branch $GIT_BRANCH)} ${GIT_COMMIT:+@ $GIT_COMMIT}"
  if [[ -d "$SPELL_DB/$NAME" ]]; then
    echo "INSTALLED: yes ($(<"$SPELL_DB/$NAME/version"))"
  else
    echo "INSTALLED: no"
  fi
}

cmd_list() {
  [[ -d "$SPELL_DB" ]] || return 0
  for d in "$SPELL_DB"/*; do
    [[ -d "$d" ]] || continue
    local n v r
    n=$(basename "$d")
    v=$(<"$d/version")
    r=$(<"$d/release" 2>/dev/null || echo 1)
    echo "$n $v-$r"
  done
}

########################################
# Limpeza
########################################

clean() {
  local what="${1:-build}";
  case "$what" in
    build) rm -rf "$SPELL_WORK"/*; ok "Limpou builds";;
    src)   rm -rf "$SPELL_SRC"/*; ok "Limpou downloads";;
    bin)   rm -rf "$SPELL_BINREPO"/*; ok "Limpou binrepo";;
    all)   rm -rf "$SPELL_WORK"/* "$SPELL_SRC"/* "$SPELL_BINREPO"/*; ok "Limpou tudo";;
    *)     err "Opção inválida: $what"; exit 1;;
  esac
}

########################################
# Instalação respeitando dependências
########################################

install_with_deps() {
  local targets=("$@")
  mapfile -t order < <(topo_order "${targets[@]}")
  info "Ordem de build: ${order[*]}"
  local p
  for p in "${order[@]}"; do install_from_source "$p"; done
}

remove_with_reverse_deps() {
  local targets=("$@")
  mapfile -t order < <(reverse_topo_order "${targets[@]}")
  info "Ordem de remoção: ${order[*]}"
  local p
  for p in "${order[@]}"; do remove_package "$p"; done
}

########################################
# Scaffold de fórmula
########################################

scaffold() {
  local name="$1"; local path="$SPELL_FORMULAE/$name.spell"
  [[ -e "$path" ]] && { err "Já existe: $path"; exit 1; }
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'EOF'
# Exemplo de fórmula spell (edite os campos)
NAME="hello"
VERSION="2.12.1"
RELEASE=1
URL="https://ftp.gnu.org/gnu/hello/hello-2.12.1.tar.xz"
SHA256="b7e4469d5f0f0c3ad0a2a51421e0b2d0f1a54f2b0a35b1f2aa4a5e1c6f1b8c9d"
DEPENDS=( )
# PATCHES=( patches/ )

BUILD() {
  ./configure --prefix=/usr
  make -j"$(nproc 2>/dev/null || echo 1)"
}

INSTALL() {
  make DESTDIR="$DESTDIR" install
}
EOF
  ok "Fórmula criada: $path"
}

########################################
# CLI
########################################

usage() {
  cat <<EOF
spell ${VERSION}
Uso: spell <comando> [args]

Comandos principais:
  init                          Inicializa diretórios
  create <nome>                 Cria esqueleto de fórmula
  fetch <pkg>                   Baixa fonte (curl/git)
  unpack <pkg>                  Descompacta para workdir
  patch <pkg>                   Aplica patches
  build <pkg>                   Compila e prepara DESTDIR
  bin   <pkg>                   Gera pacote binário (.tar.zst)
  install <pkg>                 Compila e instala (com DESTDIR/fakeroot)
  install-order <pkgs...>       Instala com resolução topológica (deps primeiro)
  remove <pkg>                  Remove pacote instalado
  remove-order <pkgs...>        Remove em ordem reversa de dependências
  search <texto>                Procura por fórmulas
  info <pkg>                    Informações da fórmula + status
  list                          Lista instalados
  upgrade <pkg|--all>           Atualiza para a versão da fórmula
  sync                          Sincroniza estado para repo git
  clean [build|src|bin|all]     Limpa diretórios de trabalho

Opções de ambiente:
  SPELL_COLOR=0 desativa cores; SPELL_SPINNER=0 desativa spinner
Diretórios:
  Fórmulas: $SPELL_FORMULAE
  Estado:   $SPELL_HOME
EOF
}

main() {
  local cmd="${1:-}"; shift || true
  case "${cmd}" in
    init) ok "Spell inicializado em $SPELL_HOME";;
    create) scaffold "${1:?informe o nome}";;
    fetch) fetch_source "${1:?pkg}";;
    unpack) unpack_to_workdir "${1:?pkg}";;
    patch) apply_patches "${1:?pkg}";;
    build) build_package "${1:?pkg}" >/dev/null;;
    bin) make_binary "${1:?pkg}";;
    install) install_from_source "${1:?pkg}";;
    install-order) install_with_deps "$@";;
    remove) remove_package "${1:?pkg}";;
    remove-order) remove_with_reverse_deps "$@";;
    search) cmd_search "${1:-}";;
    info) cmd_info "${1:?pkg}";;
    list) cmd_list;;
    upgrade)
      if [[ "${1:-}" == "--all" ]]; then
        shopt -s nullglob
        for f in "$SPELL_FORMULAE"/*.spell; do n=$(basename "$f" .spell); upgrade_one "$n"; done
      else
        upgrade_one "${1:?pkg}"
      fi
      ;;
    sync) git_sync ;;
    clean) clean "${1:-build}" ;;
    ""|help|-h|--help) usage ;;
    *) err "Comando desconhecido: $cmd"; usage; exit 1 ;;
  esac
}

main "$@"
