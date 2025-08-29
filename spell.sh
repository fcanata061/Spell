#!/usr/bin/env bash
# spell — gerenciador de programas source-based para LFS
# Autor: você + ChatGPT (GPT-5 Thinking)
# Licença: MIT
#
# Objetivos (resumo):
# - Tudo dirigível por variáveis e receitas YAML simples
# - Baixa com curl/git, descompacta (tar.{gz,bz2,xz,zst}, zip)
# - Patch por diretório local ou URL(s)
# - Build com DESTDIR/fakeroot; empacota (tar) antes de instalar
# - Registro + logs
# - Instalação, remoção (uninstall) e reversão
# - Resolução de dependências por ordenação topológica (tsort)
# - "build" faz tudo menos instalar; "upgrade"; "search"; "fix"/"revdev"; limpeza; órfãos
# - Saída colorida + spinner
#
# Requisitos base: bash, coreutils, curl, git, tar, patch, find, awk, sed, tsort.
# O fakeroot é opcional (se existir será usado).

set -euo pipefail
IFS=$'\n\t'

################################################################################
# Configuração (variáveis expansíveis)
################################################################################
: "${SPELL_ROOT:=/var/lib/spell}"             # estado e banco local
: "${SPELL_RECIPES_DIR:=${SPELL_ROOT}/recipes}" # onde ficam as receitas YAML
: "${SPELL_BUILD_ROOT:=${SPELL_ROOT}/build}"    # diretórios de trabalho por pacote
: "${SPELL_SRC_CACHE:=${SPELL_ROOT}/src}"       # cache de downloads
: "${SPELL_PKG_DIR:=${SPELL_ROOT}/pkgs}"        # pacotes binários gerados (tar)
: "${SPELL_LOG_DIR:=${SPELL_ROOT}/logs}"        # logs de build/instalação
: "${SPELL_DB_DIR:=${SPELL_ROOT}/db}"           # registros por pacote instalado
: "${SPELL_GIT_REPO:=}"                         # opcional: repo git para sync (receitas/estado)
: "${SPELL_SUDO:=}"                             # ex.: SPELL_SUDO=sudo se precisar
: "${SPELL_PREFIX:=/usr}"                       # prefixo padrão
: "${SPELL_JOBS:=$(nproc 2>/dev/null || echo 1)}" # paralelismo sugerido
: "${SPELL_COLOR:=auto}"                        # auto|always|never
: "${SPELL_SPINNER:=1}"                         # 1=liga, 0=desliga
: "${DESTDIR_BASE:=/tmp/spell-destdir}"         # raiz DESTDIRs

# Carregar rc local (opcional)
[ -f /etc/spellrc ] && . /etc/spellrc || true
[ -f "$HOME/.spellrc" ] && . "$HOME/.spellrc" || true

mkdir -p "$SPELL_RECIPES_DIR" "$SPELL_BUILD_ROOT" "$SPELL_SRC_CACHE" \
  "$SPELL_PKG_DIR" "$SPELL_LOG_DIR" "$SPELL_DB_DIR"

################################################################################
# Colorização e UI
################################################################################
_supports_color() {
  case "$SPELL_COLOR" in
    always) return 0;;
    never) return 1;;
    auto) [ -t 1 ] && return 0 || return 1;;
  esac
}

if _supports_color; then
  c_reset='\033[0m'; c_dim='\033[2m'; c_bold='\033[1m'
  c_red='\033[31m'; c_green='\033[32m'; c_yellow='\033[33m'; c_blue='\033[34m'
else
  c_reset=''; c_dim=''; c_bold=''; c_red=''; c_green=''; c_yellow=''; c_blue=''
fi

log()  { printf "%b[spell]%b %s\n" "$c_dim" "$c_reset" "$*"; }
info() { printf "%b[✓]%b %s\n" "$c_green" "$c_reset" "$*"; }
warn() { printf "%b[!]%b %s\n" "$c_yellow" "$c_reset" "$*"; }
err()  { printf "%b[✗]%b %s\n" "$c_red" "$c_reset" "$*" >&2; }

_spinner() {
  [ "${SPELL_SPINNER}" = 1 ] || { "$@"; return $?; }
  ( "$@" ) &
  pid=$!
  spin='|/-\\'
  i=0
  while kill -0 $pid 2>/dev/null; do
    i=$(( (i+1) % 4 ))
    printf "\r%b[%s]%b %s" "$c_blue" "${spin:$i:1}" "$c_reset" "$*"
    sleep 0.1
  done
  wait $pid; rc=$?
  printf "\r%*s\r" $(( ${#*} + 8 )) "" # limpa linha
  return $rc
}

################################################################################
# Utilidades
################################################################################
need() { command -v "$1" >/dev/null 2>&1 || { err "Requer: $1"; exit 1; }; }
NEEDED=(bash curl git tar patch awk sed tsort)
for n in "${NEEDED[@]}"; do need "$n"; done

_has() { command -v "$1" >/dev/null 2>&1; }
_use_fakeroot() { _has fakeroot && echo fakeroot || true; }
_ts() { date +"%Y-%m-%d_%H-%M-%S"; }

# Segurança mínima de path
umask 022

################################################################################
# Mini-parser YAML (chaves de 1º nível e listas simples; blocks com "|" suportados)
################################################################################
# Limitações: YAML simples (UTF-8). Para receitas avançadas, use apenas:
#  key: value
#  key: |
#    linhas...
#  key:
#    - item1
#    - item2
#  key:
#    subkey: value   (apenas um nível extra para 'source')
#  source:
#    type: url|git
#    url:  ... (ou repo: ...; ref: ...)
#
# As funções abaixo extraem valores de topo e blocos.

_yaml_val() { # _yaml_val KEY FILE
  awk -v k="^"$1"\\s*:" '
    $0 ~ k {
      sub(/^[^:]+:\s*/, ""); print; exit
    }
  ' "$2" | sed 's/^"\|"$//g'
}

_yaml_block() { # _yaml_block KEY FILE -> imprime bloco (|) sem indentação inicial
  awk -v k="^"$1"\\s*:\s*\|" '
    $0 ~ k { in=1; next }
    in {
      if ($0 ~ /^[^[:space:]-][^:]*:\s*/) { in=0; exit } # próxima chave topo
      sub(/^  /, ""); print
    }
  ' "$2"
}

_yaml_list() { # _yaml_list KEY FILE -> itens "- ..."
  awk -v k="^"$1"\\s*:\s*$" '
    $0 ~ k { in=1; next }
    in {
      if ($0 ~ /^[^[:space:]-][^:]*:\s*/) { in=0; exit }
      if ($0 ~ /^\s*-\s*/) { sub(/^\s*-\s*/,""); print }
    }
  ' "$2"
}

_yaml_mapval() { # _yaml_mapval PARENTKEY CHILDKEY FILE
  awk -v p="^"$1"\\s*:\s*$" -v c="^\s*"$2"\\s*:\" '
    $0 ~ p { in=1; next }
    in {
      if ($0 ~ /^[^[:space:]-][^:]*:\s*/) { in=0; exit }
      if ($0 ~ c) { sub(/^\s*[^:]+:\s*/, ""); print; exit }
    }
  ' "$3" | sed 's/^"\|"$//g'
}

################################################################################
# Receita: leitura
################################################################################
load_recipe() { # NAME -> exporta variáveis RECIPE_*
  local name="$1" file="$SPELL_RECIPES_DIR/$1.yaml"
  [ -f "$file" ] || { err "Receita não encontrada: $name"; exit 1; }

  RECIPE_NAME=$( _yaml_val name "$file" ); export RECIPE_NAME
  RECIPE_VERSION=$( _yaml_val version "$file" ); export RECIPE_VERSION
  RECIPE_DESC=$( _yaml_val description "$file" ); export RECIPE_DESC
  RECIPE_HOMEPAGE=$( _yaml_val homepage "$file" ); export RECIPE_HOMEPAGE
  RECIPE_LICENSE=$( _yaml_val license "$file" ); export RECIPE_LICENSE
  RECIPE_DEPENDS=( $( _yaml_list depends "$file" ) ); export RECIPE_DEPENDS

  SRC_TYPE=$( _yaml_mapval source type "$file" ); export SRC_TYPE
  SRC_URL=$( _yaml_mapval source url "$file" ); export SRC_URL
  SRC_REPO=$( _yaml_mapval source repo "$file" ); export SRC_REPO
  SRC_REF=$( _yaml_mapval source ref "$file" ); export SRC_REF

  PATCHES=( $( _yaml_list patches "$file" ) ); export PATCHES

  RECIPE_BUILD=$( _yaml_block build "$file" ); export RECIPE_BUILD
  RECIPE_INSTALL=$( _yaml_block install "$file" ); export RECIPE_INSTALL

  # Defaults
  : "${RECIPE_NAME:=$name}"
  : "${RECIPE_VERSION:=0}"
  : "${SRC_TYPE:=url}"
  : "${RECIPE_INSTALL:=$'make DESTDIR="$DESTDIR" install'}"
  : "${RECIPE_BUILD:=$'./configure --prefix="$SPELL_PREFIX"\nmake -j"$SPELL_JOBS}"

  export SRC_TYPE SRC_URL SRC_REPO SRC_REF
}

################################################################################
# Download & unpack
################################################################################
fetch_source() { # NAME -> retorna SRCDIR
  local name="$1"; load_recipe "$name"
  local builddir="$SPELL_BUILD_ROOT/$RECIPE_NAME-$RECIPE_VERSION"
  rm -rf "$builddir"; mkdir -p "$builddir"

  case "$SRC_TYPE" in
    url)
      [ -n "$SRC_URL" ] || { err "source.url ausente"; exit 1; }
      local fname="$SPELL_SRC_CACHE/$(basename "$SRC_URL")"
      if [ ! -f "$fname" ]; then
        _spinner curl -L --fail -o "$fname" "$SRC_URL"
        info "Baixado: $fname"
      fi
      unpack "$fname" "$builddir"
      ;;
    git)
      [ -n "$SRC_REPO" ] || { err "source.repo ausente"; exit 1; }
      _spinner git clone --depth 1 ${SRC_REF:+--branch "$SRC_REF"} "$SRC_REPO" "$builddir/src"
      ;;
    *) err "source.type desconhecido: $SRC_TYPE"; exit 1;;
  esac
  echo "$builddir"
}

unpack() { # ARCHIVE DESTDIR
  local a="$1" d="$2"
  mkdir -p "$d/src"
  case "$a" in
    *.tar.gz|*.tgz)     tar -xzf "$a" -C "$d/src" ;;
    *.tar.bz2|*.tbz2)   tar -xjf "$a" -C "$d/src" ;;
    *.tar.xz|*.txz)     tar -xJf "$a" -C "$d/src" ;;
    *.tar.zst|*.tzst)   tar --zstd -xf "$a" -C "$d/src" ;;
    *.zip)              unzip -q "$a" -d "$d/src" ;;
    *.tar)              tar -xf "$a" -C "$d/src" ;;
    *) err "Formato de arquivo não suportado: $a"; exit 1;;
  esac
  # Se criou diretório único, entrar nele
  local first
  first=$(find "$d/src" -mindepth 1 -maxdepth 1 -type d | head -n1 || true)
  [ -n "$first" ] && mv "$first" "$d/srcdir" || mv "$d/src" "$d/srcdir"
}

################################################################################
# Patches
################################################################################
apply_patches() {
  local builddir="$1"
  [ ${#PATCHES[@]} -eq 0 ] && return 0 || true
  pushd "$builddir/srcdir" >/dev/null
  for p in "${PATCHES[@]}"; do
    if [ -d "$p" ]; then
      find "$p" -type f -name '*.patch' -o -name '*.diff' | sort | while read -r f; do
        info "patch < $f"
        patch -p1 <"$f"
      done
    else
      # URL ou arquivo
      if [[ "$p" =~ ^https?:// ]]; then
        tmp="$SPELL_SRC_CACHE/patch-$(basename "$p")"
        curl -L --fail -o "$tmp" "$p"
        patch -p1 <"$tmp"
      else
        patch -p1 <"$p"
      fi
    fi
  done
  popd >/dev/null
}

################################################################################
# Build & Install & Package
################################################################################
run_build() {
  local name="$1"; load_recipe "$name"
  local builddir=$(fetch_source "$name")
  apply_patches "$builddir"

  local logf="$SPELL_LOG_DIR/${RECIPE_NAME}-build-$(_ts).log"
  pushd "$builddir/srcdir" >/dev/null
  info "Build: $RECIPE_NAME-$RECIPE_VERSION"
  printf "%s\n" "$RECIPE_BUILD" > "$builddir/BUILD.sh"
  chmod +x "$builddir/BUILD.sh"
  ( set -o pipefail; _spinner bash -e "$builddir/BUILD.sh" 2>&1 | tee "$logf" >/dev/null )
  popd >/dev/null
  echo "$builddir"
}

package_stage() {
  local name="$1"; load_recipe "$name"
  local builddir="$2"
  local dest="${DESTDIR_BASE}/${RECIPE_NAME}-${RECIPE_VERSION}"
  rm -rf "$dest"; mkdir -p "$dest"

  local logf="$SPELL_LOG_DIR/${RECIPE_NAME}-install-$(_ts).log"
  pushd "$builddir/srcdir" >/dev/null
  local installer="$builddir/INSTALL.sh"
  printf "%s\n" "$RECIPE_INSTALL" > "$installer"; chmod +x "$installer"
  info "Instala (DESTDIR staging): $RECIPE_NAME"
  ( set -o pipefail; DESTDIR="$dest" _spinner bash -e "$installer" 2>&1 | tee -a "$logf" >/dev/null )
  popd >/dev/null

  # Criar pacote binário tar
  local pkg="$SPELL_PKG_DIR/${RECIPE_NAME}-${RECIPE_VERSION}.tar.zst"
  ( cd "$dest" && tar --zstd -cf "$pkg" . )
  info "Pacote criado: $pkg"
  echo "$pkg|$dest"
}

install_pkg() {
  local name="$1"; load_recipe "$name"
  local pkg_staging="$2"; local pkg="${pkg_staging%%|*}"; local stage="${pkg_staging##*|}"

  local use_fk=$(_use_fakeroot)
  info "Instalando no sistema (${use_fk:+com fakeroot})"
  if [ -n "$use_fk" ]; then
    $use_fk sh -c "cd '$stage' && cp -a . /"
  else
    ${SPELL_SUDO:-} sh -c "cd '$stage' && cp -a . /"
  fi

  # Manifesto de arquivos
  local manifest="$SPELL_DB_DIR/${RECIPE_NAME}.manifest"
  ( cd "$stage" && find . -type f -o -type l -o -type d | sed 's#^\.##' | sort ) > "$manifest"

  # Registro de metadados
  local meta="$SPELL_DB_DIR/${RECIPE_NAME}.meta"
  {
    echo "name: $RECIPE_NAME"
    echo "version: $RECIPE_VERSION"
    echo "installed_at: $(_ts)"
    echo "depends: ${RECIPE_DEPENDS[*]:-}"
    echo "explicit: yes"
  } > "$meta"
  info "Registrado: $RECIPE_NAME $RECIPE_VERSION"
}

uninstall_pkg() {
  local name="$1"
  local manifest="$SPELL_DB_DIR/${name}.manifest"
  [ -f "$manifest" ] || { warn "Não instalado: $name"; return 0; }
  tac "$manifest" | while read -r path; do
    [ -z "$path" ] && continue
    ${SPELL_SUDO:-} rm -f -- "$path" 2>/dev/null || true
    # limpar diretórios vazios
    d="$(dirname "$path")"
    while [ "$d" != "/" ]; do
      rmdir "$d" 2>/dev/null || break
      d="$(dirname "$d")"
    done
  done
  rm -f "$manifest" "$SPELL_DB_DIR/${name}.meta"
  info "Removido: $name"
}

################################################################################
# Dependências — grafo e ordenação topológica
################################################################################
_depends_of() { # nome -> lista dependências
  local f="$SPELL_RECIPES_DIR/$1.yaml"; [ -f "$f" ] || return 0
  _yaml_list depends "$f"
}

_build_graph() { # nomes... -> arestas "dep nome"
  for n in "$@"; do
    for d in $(_depends_of "$n"); do
      echo "$d $n"
    done
  done
}

_toposort() { # lê arestas em stdin -> ordem topo (tsort)
  tsort || true
}

_order_install() { # nomes... -> ordem topo
  local edges=$(_build_graph "$@")
  if [ -n "$edges" ]; then
    printf "%s\n" "$edges" | _toposort
  else
    printf "%s\n" "$@"
  fi
}

_order_remove() { # nomes... -> ordem reversa segura (dependentes antes)
  local edges=$(_build_graph "$@")
  if [ -n "$edges" ]; then
    { printf "%s\n" "$edges" | _toposort; printf "%s\n" "$@"; } | awk '!seen[$0]++' | tac
  else
    printf "%s\n" "$@"
  fi
}

################################################################################
# Órfãos e correções
################################################################################
mark_auto() { # marca pacote como instalado automaticamente
  local n="$1"; local m="$SPELL_DB_DIR/${n}.meta"; [ -f "$m" ] || return 0
  sed -i 's/^explicit: .*/explicit: no/' "$m" || echo 'explicit: no' >> "$m"
}

list_installed() { ls "$SPELL_DB_DIR"/*.meta 2>/dev/null | xargs -r -n1 basename | sed 's/\.meta$//' || true; }

list_orphans() {
  local installed deps all
  installed=( $(list_installed) )
  declare -A needed=()
  for n in "${installed[@]}"; do
    depstr=$(awk -F': ' '/^depends:/{print $2}' "$SPELL_DB_DIR/${n}.meta" || true)
    for d in $depstr; do needed[$d]=1; done
  done
  for n in "${installed[@]}"; do
    explicit=$(awk -F': ' '/^explicit:/{print $2}' "$SPELL_DB_DIR/${n}.meta" || echo yes)
    if [ -z "${needed[$n]:-}" ] && [ "$explicit" != "yes" ]; then
      echo "$n"
    fi
  done
}

fix_registry() { # "revdev evoluído" — reconstroi manifests faltantes a partir de pacote
  for meta in "$SPELL_DB_DIR"/*.meta; do
    [ -e "$meta" ] || continue
    n=$(awk -F': ' '/^name:/{print $2}' "$meta")
    v=$(awk -F': ' '/^version:/{print $2}' "$meta")
    man="$SPELL_DB_DIR/${n}.manifest"
    if [ ! -f "$man" ] && [ -f "$SPELL_PKG_DIR/${n}-${v}.tar.zst" ]; then
      warn "Manifesto ausente de $n – tentando reconstruir a partir do pacote"
      tmp="$(mktemp -d)"; tar --zstd -tf "$SPELL_PKG_DIR/${n}-${v}.tar.zst" | sed 's/^\./ /' >/dev/null 2>&1 || true
      tar --zstd -tf "$SPELL_PKG_DIR/${n}-${v}.tar.zst" | sed 's#^#/#' | sort > "$man"
      rm -rf "$tmp"
    fi
  done
}

################################################################################
# Comandos
################################################################################
cmd_build() { # build sem instalar
  local targets=("$@")
  local order=$(_order_install "${targets[@]}")
  for n in $order; do
    info "[build] $n"
    bdir=$(run_build "$n")
    package_stage "$n" "$bdir" >/dev/null
  done
}

cmd_install() { # build + package + install
  local targets=("$@")
  local order=$(_order_install "${targets[@]}")
  for n in $order; do
    info "[install] $n"
    bdir=$(run_build "$n")
    pkgstg=$(package_stage "$n" "$bdir")
    install_pkg "$n" "$pkgstg"
  done
}

cmd_remove() { # remove em ordem reversa segura
  local order=$(_order_remove "$@")
  for n in $order; do uninstall_pkg "$n"; done
}

cmd_search() {
  local q="$1"
  for f in "$SPELL_RECIPES_DIR"/*.yaml; do
    [ -e "$f" ] || continue
    name=$( _yaml_val name "$f" ); [ -n "$name" ] || name=$(basename "$f" .yaml)
    desc=$( _yaml_val description "$f" )
    if echo "$name $desc" | grep -iE "$q" >/dev/null; then
      printf "%s - %s\n" "$name" "${desc:-sem descrição}"
    fi
  done
}

cmd_upgrade() {
  local targets=("$@")
  [ ${#targets[@]} -gt 0 ] || targets=( $(list_installed) )
  for n in "${targets[@]}"; do
    load_recipe "$n"
    warn "Rebuild→install: $RECIPE_NAME $RECIPE_VERSION"
    bdir=$(run_build "$n")
    pkgstg=$(package_stage "$n" "$bdir")
    install_pkg "$n" "$pkgstg"
  done
}

cmd_clean() {
  rm -rf "$SPELL_BUILD_ROOT"/* || true
  find "$SPELL_SRC_CACHE" -type f -mtime +30 -delete 2>/dev/null || true
  info "Limpeza concluída"
}

cmd_orphans() { list_orphans; }

cmd_fix() { fix_registry; info "Banco verificado."; }

cmd_sync() { # commit state/receitas no git
  [ -n "$SPELL_GIT_REPO" ] || { warn "SPELL_GIT_REPO não configurado"; return 0; }
  if [ ! -d "$SPELL_GIT_REPO/.git" ]; then
    git init "$SPELL_GIT_REPO"
  fi
  rsync -a --delete "$SPELL_RECIPES_DIR"/ "$SPELL_GIT_REPO/recipes/"
  rsync -a "$SPELL_DB_DIR"/ "$SPELL_GIT_REPO/db/"
  pushd "$SPELL_GIT_REPO" >/dev/null
  git add -A
  git commit -m "spell sync $(date -Is)" || true
  popd >/dev/null
  info "Sync git: $SPELL_GIT_REPO"
}

cmd_mark_auto() { for n in "$@"; do mark_auto "$n"; done; }

usage() {
  cat <<EOF
${c_bold}spell${c_reset} — gerenciador de programas (source-based)

Uso:
  spell build <pacote...>       # compila e empacota (não instala)
  spell install <pacote...>     # build + package + install (com DESTDIR)
  spell remove <pacote...>      # desinstala (ordem reversa)
  spell search <regex>          # busca em receitas
  spell upgrade [<pacote...>]   # rebuild + install (default: todos instalados)
  spell clean                   # limpa diretórios de trabalho/cache antigos
  spell orphans                 # lista órfãos (auto e não necessários)
  spell mark-auto <pacote...>   # marca como instalado automaticamente
  spell fix                     # correções de banco/manifests
  spell sync                    # sincroniza receitas+db com repo git (SPELL_GIT_REPO)

Diretórios:
  ROOT:     $SPELL_ROOT
  recipes:  $SPELL_RECIPES_DIR
  build:    $SPELL_BUILD_ROOT
  src:      $SPELL_SRC_CACHE
  pkgs:     $SPELL_PKG_DIR
  db:       $SPELL_DB_DIR
  logs:     $SPELL_LOG_DIR

Variáveis úteis:
  SPELL_PREFIX, SPELL_JOBS, SPELL_COLOR, SPELL_SPINNER, DESTDIR_BASE, SPELL_GIT_REPO, SPELL_SUDO

Receita YAML mínima (exemplo):
--------------------------------
# Salve como: $SPELL_RECIPES_DIR/hello.yaml
name: hello
version: 2.12
description: GNU Hello
homepage: https://www.gnu.org/software/hello/
license: GPL-3.0
source:
  type: url
  url: https://ftp.gnu.org/gnu/hello/hello-2.12.tar.xz
# patches: []
depends:
  - libc
build: |
  ./configure --prefix="${SPELL_PREFIX}"
  make -j"${SPELL_JOBS}"
install: |
  make DESTDIR="${DESTDIR}" install
--------------------------------

Dicas:
- Para usar fakeroot: instale fakeroot (opcional). Se presente, será usado.
- Para Sync git: exporte SPELL_GIT_REPO=/caminho/do/repo e rode `spell sync`.
- Para remover órfãos: `spell orphans | xargs -r spell remove` (use com cuidado).
EOF
}

main() {
  cmd="${1:-}"; shift || true
  case "$cmd" in
    build)    cmd_build "$@" ;;
    install)  cmd_install "$@" ;;
    remove)   cmd_remove "$@" ;;
    search)   cmd_search "${1:-}" ;;
    upgrade)  cmd_upgrade "$@" ;;
    clean)    cmd_clean ;;
    orphans)  cmd_orphans ;;
    mark-auto) cmd_mark_auto "$@" ;;
    fix)      cmd_fix ;;
    sync)     cmd_sync ;;
    ""|-h|--help|help) usage ;;
    *) err "Comando inválido: $cmd"; usage; exit 2;;
  esac
}

main "$@"

# Fim do arquivo
