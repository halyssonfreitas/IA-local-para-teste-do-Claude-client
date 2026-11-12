#!/usr/bin/env bash
# =============================================================================
#  claude-llm-setup.sh  (v1.1)
#  Assistente para usar o Claude Code com:
#    🐳 UM modelo LOCAL rodando em Docker (Ollama), ou
#    ☁️  VÁRIOS modelos EXTERNOS (Anthropic API, OpenRouter, Vertex, Bedrock...)
#
#  Regras:
#    • Todo modelo local roda em Docker. Só 1 modelo local por vez.
#    • Modelos externos: pode cadastrar quantos quiser.
#    • O script sempre mostra o que fez e como fazer o mesmo "na mão".
#
#  Compatível com bash 3.2+ (macOS) e Linux/WSL.
# =============================================================================

if [ -z "${BASH_VERSION:-}" ]; then echo "Execute com: bash $0"; exit 1; fi

VERSION="1.1"
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/claude-llm"
PROFILES_DIR="$CFG_DIR/profiles"
ACTIVE_FILE="$CFG_DIR/active"
BIN_DIR="$HOME/.local/bin"
WRAPPER="$BIN_DIR/claude-llm"
OLLAMA_PORT=11434
OLLAMA_IMAGE="ollama/ollama:latest"
ROCM_IMAGE="ollama/ollama:rocm"
CONTAINER="claude-llm-ollama"
VOLUME="claude-llm-ollama"

# Catálogo: tag Ollama | memória necessária (GB) | disco (GB) | serve de agente? | nota
MODELS=(
  "qwen2.5-coder:3b|4|2|n|Só para testar a instalação"
  "qwen2.5-coder:7b|7|5|n|Bom para código, fraco como agente"
  "qwen3:8b|8|6|y|Entrada razoável para tool calling"
  "qwen2.5-coder:14b|12|9|y|Agente para tarefas simples"
  "gpt-oss:20b|16|14|y|Bom em raciocínio e ferramentas"
  "devstral:24b|18|15|y|Focado em agentes de código"
  "qwen3-coder:30b|24|19|y|Melhor custo-benefício p/ Claude Code"
  "gpt-oss:120b|80|65|y|Muito capaz, exige máquina grande"
)

# ─────────────────────────────── Cores e UI ───────────────────────────────────
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; D=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'
  BLU=$'\033[34m'; MAG=$'\033[35m'; CYN=$'\033[36m'; Z=$'\033[0m'
else
  B=""; D=""; RED=""; GRN=""; YEL=""; BLU=""; MAG=""; CYN=""; Z=""
fi

LINE="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
banner()  { printf "\n${CYN}${B}%s\n  %s\n%s${Z}\n" "$LINE" "$1" "$LINE"; }
section() { printf "\n${BLU}${B}▌ %s${Z}\n" "$1"; }
ok()      { printf "  ✅ %s\n" "$1"; }
warn()    { printf "  🟡 ${YEL}%s${Z}\n" "$1"; }
err()     { printf "  ❌ ${RED}%s${Z}\n" "$1"; }
info()    { printf "  💡 %s\n" "$1"; }
row()     { printf "  %s %-18s %s\n" "$1" "$2" "$3"; }
explain() { printf "  📘 ${B}Por quê / o quê:${Z} %s\n" "$*"; }

manual() {
  printf "  🖐️  ${MAG}${B}Fazendo na mão:${Z}\n"
  local l
  for l in "$@"; do
    case "$l" in
      " "*|"#"*) printf "      ${MAG}%s${Z}\n" "$l" ;;
      *)         printf "      ${D}\$ ${Z}${MAG}%s${Z}\n" "$l" ;;
    esac
  done
}

run() {
  printf "  ▶️  ${GRN}Executando:${Z} ${B}%s${Z}\n" "$1"
  bash -c "$1"
  local rc=$?
  if [ $rc -eq 0 ]; then printf "  ✅ Concluído.\n"
  else printf "  ❌ ${RED}Falhou (código %s).${Z}\n" "$rc"; fi
  return $rc
}

run_steps() {
  local s
  for s in "$@"; do run "$s" || return 1; done
  return 0
}

ask_yn() {  # ask_yn "pergunta" [s|n]  → retorna 0 se "sim"
  local def="${2:-s}" hint ans
  if [ "$def" = "s" ]; then hint="[S/n]"; else hint="[s/N]"; fi
  while true; do
    read -r -p "  ❓ $1 $hint " ans || { echo; exit 1; }
    ans="$(printf '%s' "${ans:-$def}" | tr 'A-Z' 'a-z')"
    case "$ans" in
      s|sim|y|yes) return 0 ;;
      n|nao|não|no) return 1 ;;
    esac
    echo "     Responda com s ou n."
  done
}

ask_text() {  # ask_text "pergunta" "padrão"  → resposta em REPLY_TXT
  local ans
  read -r -p "  ✏️  $1${2:+ [$2]}: " ans || { echo; exit 1; }
  REPLY_TXT="${ans:-${2:-}}"
}

ask_secret() {  # ask_secret "pergunta"  → resposta em REPLY_TXT (não aparece na tela)
  local ans
  read -r -s -p "  🔑 $1: " ans || { echo; exit 1; }
  echo
  REPLY_TXT="$ans"
}

pause() { read -r -p "  ⏎  Pressione ENTER para continuar... " _ || exit 1; }

# ─────────────────────────────── Utilitários ──────────────────────────────────
fits()      { awk -v n="$1" -v h="$2" 'BEGIN{exit !(n<=h)}'; }
lt()        { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a<b)}'; }
calc()      { awk "BEGIN{printf \"%.1f\", $1}"; }
kb_to_gb()  { awk -v kb="$1" 'BEGIN{printf "%.1f", kb/1024/1024}'; }
slugify()   { printf '%s' "$1" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9]\{1,\}/-/g; s/^-//; s/-$//'; }
envline()   { printf 'export %s=%q\n' "$1" "$2"; }
port_in_use() { (exec 3<>"/dev/tcp/127.0.0.1/$1") >/dev/null 2>&1; }
net_check() { local c; c="$(curl -s -o /dev/null -m 6 -w '%{http_code}' "$1" 2>/dev/null)"; [ -n "$c" ] && [ "$c" != "000" ]; }

disk_free_gb() {
  local kb
  kb="$(df -Pk "$1" 2>/dev/null | awk 'NR==2{print $4}')"
  [ -z "$kb" ] && kb="$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2{print $4}')"
  kb_to_gb "${kb:-0}"
}

if [ "$(id -u)" -eq 0 ]; then SUDO=""
elif command -v sudo >/dev/null 2>&1; then SUDO="sudo"
else SUDO=""; fi

need_sudo() {
  if [ "$(id -u)" -eq 0 ] || [ -n "$SUDO" ]; then return 0; fi
  err "Preciso de root/sudo para isso e não encontrei."
  return 1
}

detect_pkg_mgr() {
  PKG=""
  local m
  for m in apt-get dnf yum pacman zypper brew; do
    if command -v "$m" >/dev/null 2>&1; then PKG="$m"; return; fi
  done
}

pkg_install_cmd() {
  case "$PKG" in
    apt-get) echo "$SUDO apt-get update && $SUDO apt-get install -y $1" ;;
    dnf)     echo "$SUDO dnf install -y $1" ;;
    yum)     echo "$SUDO yum install -y $1" ;;
    pacman)  echo "$SUDO pacman -S --noconfirm $1" ;;
    zypper)  echo "$SUDO zypper install -y $1" ;;
    brew)    echo "brew install $1" ;;
  esac
}

# ───────────────────────────── Coleta de informações ──────────────────────────
detect_gpu_linux() {
  local line f b max=0 n
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    GPU_TYPE="nvidia"
    GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n1)"
    n="$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l | tr -d ' ')"
    [ "$n" -gt 1 ] && GPU_NAME="$GPU_NAME (x$n)"
    NV_DRIVER="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1)"
    VRAM_GB="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | awk '{s+=$1} END{printf "%.1f", s/1024}')"
    return
  fi
  if command -v lspci >/dev/null 2>&1; then
    line="$(lspci 2>/dev/null | grep -Ei 'vga|3d|display' | head -n1)"
    if [ -n "$line" ]; then
      GPU_NAME="$(echo "$line" | sed 's/^[^ ]* [^:]*: //')"
      if echo "$line" | grep -qi nvidia; then
        GPU_TYPE="nvidia_nodrv"
      elif echo "$line" | grep -Eqi 'amd|radeon|advanced micro'; then
        GPU_TYPE="amd"
        for f in /sys/class/drm/card*/device/mem_info_vram_total; do
          [ -r "$f" ] || continue
          b="$(cat "$f" 2>/dev/null)"; b="${b:-0}"
          [ "$b" -gt "$max" ] && max="$b"
        done
        VRAM_GB="$(awk -v b="$max" 'BEGIN{printf "%.1f", b/1024/1024/1024}')"
        [ -e /dev/kfd ] && AMD_ROCM=1
      else
        GPU_TYPE="other"
      fi
    fi
  fi
}

collect_hw() {
  OS="$(uname -s)"; ARCH="$(uname -m)"; KERNEL="$(uname -r)"
  IS_WSL=0; grep -qi microsoft /proc/version 2>/dev/null && IS_WSL=1
  DISTRO="$OS"; AVX2="n/a"; SWAP_GB=0
  GPU_TYPE="none"; GPU_NAME="nenhuma detectada"; VRAM_GB=0; NV_DRIVER=""; AMD_ROCM=0
  local ram_kb
  if [ "$OS" = "Darwin" ]; then
    DISTRO="macOS $(sw_vers -productVersion 2>/dev/null)"
    ram_kb=$(( $(sysctl -n hw.memsize) / 1024 ))
    CPU_NAME="$(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
    CORES="$(sysctl -n hw.ncpu)"
    if [ "$ARCH" = "arm64" ]; then
      GPU_TYPE="apple"; GPU_NAME="Apple Silicon (memória unificada)"
      [ -z "$CPU_NAME" ] && CPU_NAME="Apple Silicon"
    fi
  else
    [ -r /etc/os-release ] && DISTRO="$(. /etc/os-release; echo "${PRETTY_NAME:-Linux}")"
    ram_kb="$(awk '/MemTotal/{print $2}' /proc/meminfo)"
    SWAP_GB="$(kb_to_gb "$(awk '/SwapTotal/{print $2}' /proc/meminfo)")"
    CPU_NAME="$(lscpu 2>/dev/null | awk -F: '/Model name/{sub(/^[ \t]+/,"",$2); print $2; exit}')"
    [ -z "$CPU_NAME" ] && CPU_NAME="$(awk -F: '/model name/{sub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo)"
    CORES="$(nproc)"
    if grep -qi avx2 /proc/cpuinfo 2>/dev/null; then AVX2="sim"; else AVX2="não"; fi
    detect_gpu_linux
  fi
  RAM_GB="$(kb_to_gb "$ram_kb")"
}

docker_ok() { [ "$DOCKER_STATE" = "ok" ] || [ "$DOCKER_STATE" = "sudo" ]; }

docker_details() {
  DOCKER_MEM_GB="$($DOCKER info --format '{{.MemTotal}}' 2>/dev/null | awk '{printf "%.1f", $1/1024/1024/1024}')"
  DOCKER_ROOT="$($DOCKER info --format '{{.DockerRootDir}}' 2>/dev/null)"
  $DOCKER info 2>/dev/null | grep -qi nvidia && DOCKER_NVIDIA=1
  [ -z "$DOCKER_MEM_GB" ] && DOCKER_MEM_GB=0
}

collect_docker() {
  HAS_DOCKER=0; DOCKER_STATE="ausente"; DOCKER="docker"; DOCKER_VER=""
  DOCKER_MEM_GB=0; DOCKER_NVIDIA=0; DOCKER_ROOT=""
  command -v docker >/dev/null 2>&1 || return 0
  HAS_DOCKER=1
  DOCKER_VER="$(docker --version 2>/dev/null)"
  local out rc
  out="$(docker info 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    DOCKER_STATE="ok"
  elif echo "$out" | grep -qi "permission denied"; then
    if [ "$SUDO" = "sudo" ] && sudo -n docker info >/dev/null 2>&1; then
      DOCKER="sudo docker"; DOCKER_STATE="sudo"
    else
      DOCKER_STATE="perm"
    fi
  else
    DOCKER_STATE="parado"
  fi
  if docker_ok; then docker_details; fi
}

derive_gpu_disk() {
  GPU_IN_DOCKER=0
  if [ "$GPU_TYPE" = "nvidia" ]; then
    if [ "$DOCKER_NVIDIA" = 1 ] || [ "$IS_WSL" = 1 ]; then GPU_IN_DOCKER=1; fi
  fi
  local dp="$HOME"
  [ "$OS" = "Linux" ] && [ -n "$DOCKER_ROOT" ] && dp="$DOCKER_ROOT"
  DISK_GB="$(disk_free_gb "$dp")"
}

require_docker() {
  docker_ok && return 0
  case "$DOCKER_STATE" in
    ausente) err "Docker não instalado. Use o menu 2 para instalar."; return 1 ;;
    parado)  err "Docker instalado, mas o serviço está parado. Use o menu 2 para iniciá-lo."; return 1 ;;
    perm)
      warn "Seu usuário não tem permissão no Docker. Vou tentar via sudo (pode pedir sua senha)."
      if sudo docker info >/dev/null 2>&1; then
        DOCKER="sudo docker"; DOCKER_STATE="sudo"
        docker_details; derive_gpu_disk
        return 0
      fi
      err "Não consegui usar o Docker. Veja o menu 2 (permissão)."; return 1 ;;
  esac
  return 1
}

collect_claude() {
  HAS_CLAUDE=0; CLAUDE_VER=""; CLAUDE_BIN=""
  if command -v claude >/dev/null 2>&1; then CLAUDE_BIN="$(command -v claude)"
  elif [ -x "$BIN_DIR/claude" ]; then CLAUDE_BIN="$BIN_DIR/claude"; fi
  if [ -n "$CLAUDE_BIN" ]; then
    HAS_CLAUDE=1
    CLAUDE_VER="$("$CLAUDE_BIN" --version 2>/dev/null | head -n1)"
  fi
}

collect_all() {
  collect_hw; collect_docker; collect_claude; derive_gpu_disk
}

# Define quanta memória o modelo pode usar DENTRO do Docker
compute_budget() {
  local cpu_budget
  cpu_budget="$(calc "$RAM_GB * 0.6")"
  if docker_ok && ! lt "$DOCKER_MEM_GB" 0.1; then
    cpu_budget="$(awk -v r="$RAM_GB" -v d="$DOCKER_MEM_GB" 'BEGIN{a=r*0.6; b=d*0.8; printf "%.1f", (a<b?a:b)}')"
  fi
  MODE="cpu"; FAST="$cpu_budget"; SLOW="$cpu_budget"
  if [ "$GPU_TYPE" = "nvidia" ] && [ "$GPU_IN_DOCKER" = 1 ]; then
    MODE="nvidia"; FAST="$VRAM_GB"; SLOW="$(calc "$VRAM_GB + $cpu_budget")"
  elif [ "$GPU_TYPE" = "amd" ] && [ "$AMD_ROCM" = 1 ] && ! lt "$VRAM_GB" 2; then
    MODE="amd"; FAST="$VRAM_GB"; SLOW="$(calc "$VRAM_GB + $cpu_budget")"
  fi
}

best_model() {
  BEST_TAG=""
  local m tag need disk agent note
  for m in "${MODELS[@]}"; do
    IFS='|' read -r tag need disk agent note <<< "$m"
    if [ "$agent" = "y" ] && fits "$need" "$FAST"; then BEST_TAG="$tag"; fi
  done
}

show_catalog() {
  local i=0 m tag need disk agent note st tip
  section "📚 Catálogo de modelos (memória aproximada, quantização Q4)"
  for m in "${MODELS[@]}"; do
    i=$((i+1))
    IFS='|' read -r tag need disk agent note <<< "$m"
    if fits "$need" "$FAST"; then
      if [ "$MODE" = "cpu" ]; then st="🟡 roda em CPU (lento)"; else st="🟢 cabe na GPU"; fi
    elif fits "$need" "$SLOW"; then
      st="🟠 lento (usa RAM)"
    else
      st="🔴 não cabe"
    fi
    tip=""; [ "$agent" = "n" ] && tip="  ⚠️ fraco como agente"
    printf "   %2d) %-20s %3s GB RAM · %3s GB disco  %s%s\n" "$i" "$tag" "$need" "$disk" "$st" "$tip"
    printf "       ${D}%s${Z}\n" "$note"
  done
  printf "    o) Digitar outra tag do Ollama\n"
  printf "    0) Cancelar\n"
}

# ─────────────────────── Modelos ativos: detectar e desligar ──────────────────
AC_KIND=(); AC_ID=(); AC_NAME=(); AC_DESC=()

scan_active_models() {
  AC_KIND=(); AC_ID=(); AC_NAME=(); AC_DESC=()
  local id name image mine pid p
  if docker_ok; then
    while IFS='|' read -r id name image mine; do
      [ -z "$id" ] && continue
      AC_KIND+=("docker"); AC_ID+=("$id"); AC_NAME+=("$name")
      AC_DESC+=("🐳 Container \"$name\" (imagem $image)")
    done < <($DOCKER ps --format '{{.ID}}|{{.Names}}|{{.Image}}|{{.Label "claude-llm"}}' 2>/dev/null \
             | awk -F'|' 'tolower($3) ~ /ollama|vllm|llama|localai|text-generation|lmstudio/ || $4 == "1"')
  fi
  for p in ollama llama-server llama-cli vllm; do
    for pid in $(pgrep -ix "$p" 2>/dev/null); do
      if [ -r "/proc/$pid/cgroup" ] && grep -qE 'docker|containerd|kubepods|libpod' "/proc/$pid/cgroup" 2>/dev/null; then
        continue   # processo dentro de um container, já listado acima
      fi
      AC_KIND+=("host"); AC_ID+=("$pid"); AC_NAME+=("$p")
      AC_DESC+=("🖥️  Processo \"$p\" (PID $pid) rodando FORA do Docker")
    done
  done
}

stop_one() {
  local i="$1" kind id name
  kind="${AC_KIND[$i]}"; id="${AC_ID[$i]}"; name="${AC_NAME[$i]}"
  if [ "$kind" = "docker" ]; then
    explain "'docker stop' pede ao container que termine. Os arquivos do modelo continuam no volume; só a memória é liberada."
    manual "docker stop $name"
    run "$DOCKER stop $name"
    return
  fi
  explain "Este processo roda fora do Docker. Como a regra é manter modelos no Docker (e a porta $OLLAMA_PORT precisa ficar livre), vou encerrá-lo."
  if [ "$OS" = "Linux" ] && [ "$name" = "ollama" ] && command -v systemctl >/dev/null 2>&1 \
     && systemctl is-active --quiet ollama 2>/dev/null; then
    manual "sudo systemctl stop ollama" "sudo systemctl disable ollama   # opcional: não iniciar no boot"
    run "$SUDO systemctl stop ollama"
    if ask_yn "Desativar também a inicialização automática do Ollama no boot?" s; then
      run "$SUDO systemctl disable ollama"
    fi
  elif [ "$OS" = "Darwin" ] && [ "$name" = "ollama" ]; then
    manual "osascript -e 'quit app \"Ollama\"'" "kill $id"
    run "osascript -e 'quit app \"Ollama\"' >/dev/null 2>&1; kill $id"
  else
    manual "kill $id"
    run "kill $id"
  fi
  sleep 1
}

offer_stop_active() {   # retorna 0 se, no final, não sobrou nada ativo
  scan_active_models
  local n=${#AC_ID[@]} i
  explain "Procuro containers Docker de IA (ollama, vllm, llama...) e processos de modelos rodando direto no sistema."
  manual "docker ps" "pgrep -il ollama     # ou: ps aux | grep -i ollama"
  if [ "$n" -eq 0 ]; then ok "Nenhum modelo ativo na máquina."; return 0; fi
  warn "Encontrei $n item(ns) ativo(s):"
  for ((i=0; i<n; i++)); do printf "     %d) %s\n" $((i+1)) "${AC_DESC[$i]}"; done
  info "Regra: só 1 modelo local por vez, sempre em Docker."
  for ((i=0; i<n; i++)); do
    if ask_yn "Desligar → ${AC_DESC[$i]}?" n; then stop_one "$i"; fi
  done
  scan_active_models
  [ "${#AC_ID[@]}" -eq 0 ]
}

# ─────────────────────────────── Perfis ───────────────────────────────────────
PF_SLUG=(); PF_TYPE=(); PF_LABEL=(); PICK_IDX=""

profile_field() {   # profile_field slug VARIAVEL
  local f="$PROFILES_DIR/$1.env"
  [ -f "$f" ] || return 1
  ( . "$f" >/dev/null 2>&1; eval "printf '%s' \"\${$2:-}\"" )
}

active_slug() {
  local s=""
  [ -f "$ACTIVE_FILE" ] && s="$(head -n1 "$ACTIVE_FILE")"
  if [ -n "$s" ] && [ -f "$PROFILES_DIR/$s.env" ]; then printf '%s' "$s"; fi
  return 0
}

set_active() {
  mkdir -p "$CFG_DIR"
  printf '%s\n' "$1" > "$ACTIVE_FILE"
}

load_profiles() {
  PF_SLUG=(); PF_TYPE=(); PF_LABEL=()
  local f s
  [ -d "$PROFILES_DIR" ] || return 0
  for f in "$PROFILES_DIR"/*.env; do
    [ -f "$f" ] || continue
    s="$(basename "$f" .env)"
    PF_SLUG+=("$s")
    PF_TYPE+=("$(profile_field "$s" PROFILE_TYPE)")
    PF_LABEL+=("$(profile_field "$s" PROFILE_LABEL)")
  done
}

show_profiles() {
  load_profiles
  local act i mark
  act="$(active_slug)"
  if [ "${#PF_SLUG[@]}" -eq 0 ]; then warn "Nenhum perfil cadastrado ainda (use os menus 5 e 6)."; return 1; fi
  for ((i=0; i<${#PF_SLUG[@]}; i++)); do
    mark="  "; [ "${PF_SLUG[$i]}" = "$act" ] && mark="👉"
    printf "   %s %d) %s  ${D}(%s)${Z}\n" "$mark" $((i+1)) "${PF_LABEL[$i]}" "${PF_TYPE[$i]}"
  done
  return 0
}

pick_profile() {
  PICK_IDX=""
  show_profiles || return 1
  local n ans
  n=${#PF_SLUG[@]}
  read -r -p "  👉 $1 (número, ENTER cancela): " ans || exit 1
  case "$ans" in ""|*[!0-9]*) return 1 ;; esac
  if [ "$ans" -lt 1 ] || [ "$ans" -gt "$n" ]; then err "Número inválido."; return 1; fi
  PICK_IDX=$((ans-1))
  return 0
}

write_profile() {   # write_profile slug tipo rótulo   (linhas "export" chegam por stdin)
  local slug="$1" type="$2" label="$3" f
  mkdir -p "$PROFILES_DIR"
  chmod 700 "$CFG_DIR" "$PROFILES_DIR" 2>/dev/null
  f="$PROFILES_DIR/$slug.env"
  {
    printf 'PROFILE_TYPE=%s\n' "$type"
    printf 'PROFILE_LABEL=%q\n' "$label"
    cat
  } > "$f"
  chmod 600 "$f"
}

model_envs() {   # define o mesmo modelo para todos os "apelidos" que o Claude Code usa
  envline ANTHROPIC_MODEL "$1"
  envline ANTHROPIC_DEFAULT_SONNET_MODEL "$1"
  envline ANTHROPIC_DEFAULT_OPUS_MODEL "$1"
  envline ANTHROPIC_DEFAULT_HAIKU_MODEL "$1"
  envline ANTHROPIC_SMALL_FAST_MODEL "$1"
}

show_profile_file() {   # mostra o arquivo escondendo chaves longas
  sed -E 's/^(export (ANTHROPIC_AUTH_TOKEN|ANTHROPIC_API_KEY)=).{9,}$/\1********/' "$PROFILES_DIR/$1.env" \
    | sed 's/^/      /'
}

# ─────────────────────────── Comando claude-llm (wrapper) ─────────────────────
add_path_rc() {
  local rc
  case "${SHELL:-}" in
    */zsh) rc="$HOME/.zshrc" ;;
    *) if [ "$OS" = "Darwin" ]; then rc="$HOME/.bash_profile"; else rc="$HOME/.bashrc"; fi ;;
  esac
  explain "$BIN_DIR precisa estar no PATH para você digitar 'claude' ou 'claude-llm' de qualquer pasta."
  manual "echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> $rc" "source $rc"
  if ask_yn "Adicionar essa linha ao $rc automaticamente?" s; then
    if grep -qs '.local/bin' "$rc"; then
      info "Já existe uma referência a .local/bin em $rc, não alterei nada."
    else
      printf '\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$rc"
      ok "Adicionado. Abra um novo terminal ou rode: source $rc"
    fi
  fi
}

install_wrapper() {
  section "Criando o comando claude-llm"
  explain "É um pequeno script que carrega as variáveis do perfil ativo e então chama o 'claude'. Assim você troca de modelo sem mexer em variáveis de ambiente."
  manual "mkdir -p ~/.local/bin" "# (crie o arquivo ~/.local/bin/claude-llm com o conteúdo do wrapper)" "chmod +x ~/.local/bin/claude-llm"
  mkdir -p "$BIN_DIR"
  cat > "$WRAPPER" <<'WRAP_EOF'
#!/usr/bin/env bash
# claude-llm — inicia o Claude Code com um perfil criado pelo claude-llm-setup.sh
#   claude-llm                       usa o perfil ativo
#   claude-llm --profile ext-nome    usa um perfil específico
#   (os demais argumentos vão direto para o claude)
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/claude-llm"
PROFILES_DIR="$CFG_DIR/profiles"
export PATH="$HOME/.local/bin:$PATH"

profile=""
if [ "${1:-}" = "--profile" ]; then
  profile="${2:-}"
  shift
  if [ $# -gt 0 ]; then shift; fi
fi
if [ -z "$profile" ]; then profile="$(head -n1 "$CFG_DIR/active" 2>/dev/null)"; fi

if [ -z "$profile" ] || [ ! -f "$PROFILES_DIR/$profile.env" ]; then
  echo "❌ Nenhum perfil ativo/válido. Rode o claude-llm-setup.sh primeiro."
  exit 1
fi
if ! command -v claude >/dev/null 2>&1; then
  echo "❌ Claude Code não encontrado. Rode o claude-llm-setup.sh (menu 3)."
  exit 1
fi

# limpa variáveis para que perfis diferentes não se misturem
unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_MODEL
unset ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL
unset ANTHROPIC_SMALL_FAST_MODEL CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_BEDROCK
unset CLOUD_ML_REGION ANTHROPIC_VERTEX_PROJECT_ID CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC

. "$PROFILES_DIR/$profile.env"

if [ "${PROFILE_TYPE:-}" = "local" ]; then
  if ! curl -s -m 3 -o /dev/null "${ANTHROPIC_BASE_URL}/api/tags"; then
    echo "❌ O modelo local não está rodando."
    echo "   Rode o claude-llm-setup.sh (menu 7 → ativar) ou: docker start claude-llm-ollama"
    exit 1
  fi
fi

echo "▶️  Claude Code com o perfil: ${PROFILE_LABEL:-$profile}"
exec claude "$@"
WRAP_EOF
  chmod +x "$WRAPPER"
  ok "Criado: $WRAPPER"
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) warn "$BIN_DIR não está no PATH."; add_path_rc ;;
  esac
}

ensure_wrapper() { [ -x "$WRAPPER" ] || install_wrapper; }

# ─────────────────────────── Instaladores ─────────────────────────────────────
install_tool() {
  local t="$1" cmd
  detect_pkg_mgr
  if [ -z "$PKG" ]; then
    err "Gerenciador de pacotes não identificado. Instale '$t' manualmente."
    [ "$OS" = "Darwin" ] && info "No macOS, instale o Homebrew: https://brew.sh"
    return 1
  fi
  if [ "$PKG" != "brew" ]; then need_sudo || return 1; fi
  cmd="$(pkg_install_cmd "$t")"
  explain "Instalo '$t' com o gerenciador de pacotes do seu sistema ($PKG)."
  manual "$cmd"
  run "$cmd"
}

wait_docker() {
  local i
  printf "  ⏳ Aguardando o Docker ficar pronto"
  for i in $(seq 1 60); do
    if docker info >/dev/null 2>&1 || sudo -n docker info >/dev/null 2>&1; then
      printf "\n"; ok "Docker respondendo."; return 0
    fi
    printf "."; sleep 3
  done
  printf "\n"; err "O Docker não respondeu a tempo."; return 1
}

start_docker() {
  section "Iniciando o Docker"
  if [ "$OS" = "Darwin" ]; then
    explain "No macOS o Docker é um aplicativo (Docker Desktop); preciso abri-lo."
    manual "open -a Docker"
    run "open -a Docker" || return 1
  else
    explain "No Linux o Docker é um serviço do systemd. 'enable --now' inicia agora e também em todo boot."
    need_sudo || return 1
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
      manual "sudo systemctl enable --now docker"
      run "$SUDO systemctl enable --now docker" || return 1
    else
      manual "sudo service docker start"
      run "$SUDO service docker start" || return 1
    fi
  fi
  wait_docker
}

fix_docker_perm() {
  [ "$OS" = "Darwin" ] && return 0
  section "Permissão do Docker"
  explain "Para usar 'docker' sem sudo, seu usuário precisa estar no grupo 'docker'. O efeito só vale após novo login."
  manual "sudo usermod -aG docker \$USER" "newgrp docker     # ativa o grupo nesta sessão (ou faça logout/login)"
  need_sudo || return 1
  run "$SUDO usermod -aG docker $(id -un)"
  info "Faça logout/login (ou 'newgrp docker') para valer. Até lá este script usa sudo automaticamente."
}

install_docker() {
  banner "🐳 Instalando o Docker"
  explain "O Docker isola o modelo em um container: nada de dependências espalhadas na sua máquina, e remover tudo é um comando só."
  if [ "$OS" = "Darwin" ]; then
    if ! command -v brew >/dev/null 2>&1; then
      err "Homebrew não encontrado."
      info "Baixe o Docker Desktop: https://www.docker.com/products/docker-desktop/"
      info "Ou instale o Homebrew (https://brew.sh) e rode este menu de novo."
      return 1
    fi
    manual "brew install --cask docker" "open -a Docker     # na 1ª vez, aceite os termos"
    run "brew install --cask docker" || return 1
    start_docker
    return
  fi
  if [ "$IS_WSL" = 1 ]; then
    warn "Você está no WSL. O recomendado é o Docker Desktop no Windows com integração WSL ligada."
    ask_yn "Instalar o Docker Engine dentro do WSL mesmo assim?" n || return 1
  fi
  need_sudo || return 1
  if ! command -v curl >/dev/null 2>&1; then install_tool curl || return 1; fi
  explain "Uso o script oficial get.docker.com, que detecta sua distribuição e configura o repositório."
  manual "curl -fsSL https://get.docker.com -o get-docker.sh" "sudo sh get-docker.sh"
  run "curl -fsSL https://get.docker.com -o /tmp/get-docker.sh && $SUDO sh /tmp/get-docker.sh" || return 1
  start_docker || return 1
  fix_docker_perm
}

install_nvidia_toolkit() {
  banner "🟩 NVIDIA Container Toolkit"
  explain "Permite que containers Docker usem sua GPU NVIDIA. Sem isso o modelo rodaria só em CPU, bem mais lento."
  need_sudo || return 1
  detect_pkg_mgr
  local kr="/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"
  local base="https://nvidia.github.io/libnvidia-container"
  local steps=()
  case "$PKG" in
    apt-get)
      command -v gpg >/dev/null 2>&1 || install_tool gnupg
      steps=(
        "curl -fsSL $base/gpgkey | $SUDO gpg --dearmor -o $kr"
        "curl -s -L $base/stable/deb/nvidia-container-toolkit.list | sed 's#deb https://#deb [signed-by=$kr] https://#g' | $SUDO tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null"
        "$SUDO apt-get update && $SUDO apt-get install -y nvidia-container-toolkit"
      ) ;;
    dnf|yum)
      steps=(
        "curl -s -L $base/stable/rpm/nvidia-container-toolkit.repo | $SUDO tee /etc/yum.repos.d/nvidia-container-toolkit.repo >/dev/null"
        "$SUDO $PKG install -y nvidia-container-toolkit"
      ) ;;
    *)
      err "Distribuição sem receita automática."
      info "Siga o guia oficial: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html"
      return 1 ;;
  esac
  steps+=("$SUDO nvidia-ctk runtime configure --runtime=docker" "$SUDO systemctl restart docker")
  manual "${steps[@]}"
  run_steps "${steps[@]}" || return 1
  info "Para conferir: docker run --rm --gpus=all ubuntu nvidia-smi"
}

install_claude() {
  banner "🤖 Instalar o Claude Code"
  collect_claude
  if [ "$HAS_CLAUDE" = 1 ]; then
    ok "Já instalado: ${CLAUDE_VER:-versão desconhecida} ($CLAUDE_BIN)"
    if ask_yn "Atualizar para a última versão?" n; then
      manual "claude update"
      run "\"$CLAUDE_BIN\" update"
    fi
    return 0
  fi
  explain "O Claude Code é o agente de programação que roda no terminal. Ele é só o 'cliente': o modelo (cérebro) pode ser local ou externo."
  echo "     1) Instalador nativo oficial (recomendado)"
  echo "     2) npm (precisa de Node.js 18 ou superior)"
  echo "     0) Cancelar"
  local c
  read -r -p "  👉 Escolha: " c || exit 1
  case "$c" in
    1)
      command -v curl >/dev/null 2>&1 || { install_tool curl || return 1; }
      manual "curl -fsSL https://claude.ai/install.sh | bash"
      run "curl -fsSL https://claude.ai/install.sh | bash" || return 1 ;;
    2)
      if ! command -v npm >/dev/null 2>&1; then
        err "npm não encontrado. Instale o Node.js 18+ (https://nodejs.org) ou use a opção 1."
        return 1
      fi
      manual "npm install -g @anthropic-ai/claude-code"
      run "npm install -g @anthropic-ai/claude-code" || return 1 ;;
    *) warn "Cancelado."; return 0 ;;
  esac
  collect_claude
  if [ "$HAS_CLAUDE" = 1 ]; then
    ok "Claude Code instalado: ${CLAUDE_VER:-ok} ($CLAUDE_BIN)"
    case ":$PATH:" in
      *":$BIN_DIR:"*) ;;
      *) warn "$BIN_DIR não está no PATH."; add_path_rc ;;
    esac
    info "No primeiro uso ele pode mostrar uma tela de boas-vindas/tema. Com um perfil ativo ele usa o modelo do perfil."
  else
    err "Não encontrei o comando 'claude' depois da instalação. Abra um novo terminal e rode o diagnóstico."
  fi
}

# ───────────────────────────── Diagnóstico completo ───────────────────────────
TODO=()

tool_row() {   # tool_row nome nível(req|rec|opt) descrição
  local n="$1" lvl="$2" d="$3" v
  if command -v "$n" >/dev/null 2>&1; then
    v="$("$n" --version 2>/dev/null | head -n1 | cut -c1-48)"
    row "✅" "$n" "${v:-instalado}"
  else
    case "$lvl" in
      req) row "❌" "$n" "ausente: $d"; TODO+=("tool:$n") ;;
      rec) row "🟡" "$n" "ausente: $d"; TODO+=("tool:$n") ;;
      *)   row "🟡" "$n" "ausente (opcional): $d" ;;
    esac
  fi
}

preflight() {
  banner "🩺 Diagnóstico completo da máquina"
  explain "Só leitura: nada é alterado. Olho sistema, hardware, Docker, Claude Code, ferramentas, rede, modelos ativos e perfis."
  collect_all; detect_pkg_mgr
  TODO=()

  section "🖥️  Sistema"
  row "✅" "Sistema" "$DISTRO ($ARCH)"
  row "✅" "Kernel" "$KERNEL"
  row "✅" "Bash" "$BASH_VERSION"
  [ "$IS_WSL" = 1 ] && row "🟡" "WSL" "Use Docker Desktop com integração WSL (ou Engine com systemd)"
  if [ "$(id -u)" -eq 0 ]; then row "✅" "Privilégios" "root"
  elif [ -n "$SUDO" ]; then row "✅" "Privilégios" "sudo disponível"
  else row "🟡" "Privilégios" "sem sudo: não consigo instalar pacotes de sistema"; fi
  if [ -n "$PKG" ]; then row "✅" "Pacotes" "gerenciador: $PKG"
  else row "🟡" "Pacotes" "gerenciador não identificado"; fi
  manual "uname -a" "cat /etc/os-release     # macOS: sw_vers" "sudo -v     # testa se você tem sudo"

  section "🧮 Hardware"
  row "✅" "CPU" "$CPU_NAME ($CORES threads)"
  if [ "$AVX2" = "não" ]; then row "🟡" "AVX2" "ausente: inferência em CPU será MUITO lenta"
  elif [ "$AVX2" = "sim" ]; then row "✅" "AVX2" "presente"; fi
  if lt "$RAM_GB" 8; then row "❌" "RAM" "${RAM_GB} GB: muito pouca para agentes locais"
  elif lt "$RAM_GB" 16; then row "🟡" "RAM" "${RAM_GB} GB: só modelos pequenos"
  else row "✅" "RAM" "${RAM_GB} GB"; fi
  [ "$OS" = "Linux" ] && row "✅" "Swap" "${SWAP_GB} GB"
  case "$GPU_TYPE" in
    nvidia) row "✅" "GPU" "$GPU_NAME (driver $NV_DRIVER)"; row "✅" "VRAM" "${VRAM_GB} GB" ;;
    nvidia_nodrv) row "🟡" "GPU" "$GPU_NAME: driver NVIDIA não instalado (instale manualmente)" ;;
    apple) row "🟡" "GPU" "$GPU_NAME: o Docker no macOS NÃO acessa essa GPU (só CPU)" ;;
    amd) row "🟡" "GPU" "$GPU_NAME (VRAM ~${VRAM_GB} GB, ROCm: $([ "$AMD_ROCM" = 1 ] && echo disponível || echo indisponível))" ;;
    other) row "🟡" "GPU" "$GPU_NAME: sem aceleração, usará CPU" ;;
    *) row "🟡" "GPU" "nenhuma detectada: usará CPU" ;;
  esac
  if lt "$DISK_GB" 20; then row "❌" "Disco livre" "${DISK_GB} GB: pouco (modelos têm 5 a 65 GB)"
  elif lt "$DISK_GB" 40; then row "🟡" "Disco livre" "${DISK_GB} GB: dá para modelos médios"
  else row "✅" "Disco livre" "${DISK_GB} GB"; fi
  if [ "$OS" = "Darwin" ]; then
    manual "sysctl -n machdep.cpu.brand_string" "sysctl hw.memsize" "system_profiler SPDisplaysDataType" "df -h ~"
  else
    manual "lscpu" "free -h" "nvidia-smi     # GPU NVIDIA" "lspci | grep -Ei 'vga|3d'" "df -h"
  fi

  section "🐳 Docker"
  case "$DOCKER_STATE" in
    ausente) row "❌" "Docker" "não instalado"; TODO+=("docker") ;;
    parado)  row "✅" "Docker" "$DOCKER_VER"; row "❌" "Serviço" "instalado, mas parado"; TODO+=("docker-start") ;;
    perm)    row "✅" "Docker" "$DOCKER_VER"; row "🟡" "Permissão" "usuário fora do grupo docker (usarei sudo)"; TODO+=("docker-perm") ;;
    sudo)    row "✅" "Docker" "$DOCKER_VER"; row "🟡" "Permissão" "funciona só com sudo"; TODO+=("docker-perm") ;;
    ok)      row "✅" "Docker" "$DOCKER_VER"; row "✅" "Serviço" "rodando e acessível" ;;
  esac
  if docker_ok; then
    row "✅" "Memória p/ Docker" "${DOCKER_MEM_GB} GB"
    if [ "$OS" = "Darwin" ] && lt "$DOCKER_MEM_GB" 12; then
      row "🟡" "Dica" "Aumente em Docker Desktop → Settings → Resources → Memory"
    fi
    if [ "$GPU_TYPE" = "nvidia" ]; then
      if [ "$GPU_IN_DOCKER" = 1 ]; then row "✅" "GPU no Docker" "NVIDIA acessível"
      else row "❌" "GPU no Docker" "falta o NVIDIA Container Toolkit"; TODO+=("nvidia"); fi
    fi
  fi
  if port_in_use "$OLLAMA_PORT"; then row "🟡" "Porta $OLLAMA_PORT" "em uso (normal se for seu modelo local)"
  else row "✅" "Porta $OLLAMA_PORT" "livre"; fi
  manual "docker --version" "docker info" "docker ps" "ss -ltnp | grep $OLLAMA_PORT     # quem usa a porta"

  section "🤖 Claude Code"
  if [ "$HAS_CLAUDE" = 1 ]; then
    row "✅" "Claude Code" "${CLAUDE_VER:-instalado} ($CLAUDE_BIN)"
    case ":$PATH:" in
      *":$BIN_DIR:"*) row "✅" "PATH" "$BIN_DIR está no PATH" ;;
      *) row "🟡" "PATH" "$BIN_DIR fora do PATH (o claude-llm já inclui essa pasta, mas vale corrigir)" ;;
    esac
  else
    row "❌" "Claude Code" "não instalado"; TODO+=("claude")
  fi
  manual "claude --version" "which claude" "curl -fsSL https://claude.ai/install.sh | bash     # instalar"

  section "🧰 Ferramentas"
  tool_row curl req "necessário para baixar instaladores e testar a API"
  tool_row git rec "o Claude Code trabalha melhor em repositórios git"
  tool_row jq opt "ajuda a ler respostas JSON"
  tool_row node opt "só se for instalar o Claude Code via npm"
  manual "command -v curl git jq node" "curl --version"

  section "🌐 Rede"
  if command -v curl >/dev/null 2>&1; then
    local u url name
    for u in "https://registry-1.docker.io/v2/|Docker Hub (imagens)" \
             "https://registry.ollama.ai/v2/|Ollama (modelos)" \
             "https://claude.ai/install.sh|Instalador do Claude" \
             "https://api.anthropic.com|API da Anthropic"; do
      url="${u%%|*}"; name="${u#*|}"
      if net_check "$url"; then row "✅" "$name" "acessível"; else row "🟡" "$name" "sem acesso agora"; fi
    done
  else
    row "🟡" "Rede" "sem curl, não consegui testar"
  fi
  manual "curl -I https://registry.ollama.ai/v2/"

  section "🧠 Modelos ativos"
  scan_active_models
  if [ "${#AC_ID[@]}" -eq 0 ]; then row "✅" "Modelos ativos" "nenhum"
  else
    local i
    for ((i=0; i<${#AC_ID[@]}; i++)); do row "🟡" "Ativo" "${AC_DESC[$i]}"; done
    TODO+=("active")
  fi
  manual "docker ps" "pgrep -il ollama"

  section "🗂️  Perfis do Claude Code"
  load_profiles
  if [ "${#PF_SLUG[@]}" -eq 0 ]; then row "🟡" "Perfis" "nenhum ainda (menus 5 e 6)"
  else row "✅" "Perfis" "${#PF_SLUG[@]} cadastrado(s), ativo: $(active_slug)"; fi
  if [ -x "$WRAPPER" ]; then row "✅" "claude-llm" "$WRAPPER"
  else row "🟡" "claude-llm" "será criado ao cadastrar o primeiro perfil"; fi
  manual "ls $PROFILES_DIR"

  section "📝 Resumo"
  local t
  if [ "${#TODO[@]}" -eq 0 ]; then
    ok "Tudo pronto para começar."
  else
    warn "Pendências:"
    for t in "${TODO[@]}"; do
      case "$t" in
        docker)       echo "     • Instalar o Docker → menu 2" ;;
        docker-start) echo "     • Iniciar o serviço do Docker → menu 2" ;;
        docker-perm)  echo "     • Corrigir permissão do Docker (opcional) → menu 2" ;;
        nvidia)       echo "     • Habilitar a GPU NVIDIA no Docker → menu 2" ;;
        claude)       echo "     • Instalar o Claude Code → menu 3" ;;
        active)       echo "     • Há modelo(s) ativo(s); desligue antes de subir outro → menu 4" ;;
        tool:*)       echo "     • Instalar ${t#tool:} → menu 2" ;;
      esac
    done
  fi

  compute_budget; best_model
  section "🎯 Recomendação"
  if [ "$GPU_TYPE" = "nvidia" ] && [ "$GPU_IN_DOCKER" = 0 ]; then
    info "Depois de habilitar a GPU no Docker (menu 2), a estimativa abaixo melhora."
  fi
  if [ -n "$BEST_TAG" ]; then
    ok "Melhor modelo local para agente: $BEST_TAG (modo: $MODE, ~${FAST} GB utilizáveis)"
  else
    warn "Sua máquina é limitada para um agente local com qualidade. Considere um modelo externo (menu 6), como OpenRouter com modelos gratuitos."
  fi
}

# ───────────────────────── Requisitos: instalar / corrigir ────────────────────
fix_requirements() {
  banner "🔧 Instalar / corrigir requisitos"
  explain "Verifico o que falta e peço sua confirmação antes de cada instalação. Nada é instalado sem você dizer sim."
  collect_all; detect_pkg_mgr
  local t acted=0

  section "Ferramentas básicas"
  for t in curl git jq; do
    if command -v "$t" >/dev/null 2>&1; then
      ok "$t já instalado"
    else
      acted=1
      if ask_yn "Instalar '$t'?" s; then install_tool "$t"; fi
    fi
  done

  section "Docker"
  case "$DOCKER_STATE" in
    ausente)   acted=1; if ask_yn "Docker não está instalado. Instalar agora?" s; then install_docker; fi ;;
    parado)    acted=1; if ask_yn "O serviço do Docker está parado. Iniciar?" s; then start_docker; fi ;;
    perm|sudo) acted=1; if ask_yn "Seu usuário só usa o Docker com sudo. Corrigir (grupo docker)?" s; then fix_docker_perm; fi ;;
    ok)        ok "Docker funcionando." ;;
  esac
  collect_docker; derive_gpu_disk

  section "GPU dentro do Docker"
  case "$GPU_TYPE" in
    nvidia)
      if ! docker_ok; then
        warn "Docker indisponível; revise a GPU depois."
      elif [ "$DOCKER_NVIDIA" = 1 ] || [ "$IS_WSL" = 1 ]; then
        ok "GPU NVIDIA acessível no Docker."
      else
        acted=1
        if ask_yn "Instalar o NVIDIA Container Toolkit para usar a GPU no Docker?" s; then install_nvidia_toolkit; fi
      fi ;;
    nvidia_nodrv)
      warn "Há GPU NVIDIA, mas sem driver. Instale o driver (depende da distro) e reinicie."
      manual "ubuntu-drivers devices     # Ubuntu: lista drivers" "sudo ubuntu-drivers autoinstall" "sudo reboot" ;;
    apple) info "Mac com Apple Silicon: o Docker roda só em CPU. Está tudo certo, apenas mais lento." ;;
    amd)
      if [ "$AMD_ROCM" = 1 ]; then ok "ROCm detectado: usarei a imagem ollama/ollama:rocm."
      else warn "GPU AMD sem ROCm (/dev/kfd ausente). Rodará em CPU."; fi ;;
    *) info "Sem GPU compatível: o modelo rodará em CPU." ;;
  esac

  [ "$acted" = 0 ] && ok "Nada a corrigir."
  info "Rode o menu 1 para ver o diagnóstico atualizado."
}

# ─────────────────────────────── Modelo LOCAL ─────────────────────────────────
wait_api() {
  local i
  printf "  ⏳ Aguardando a API do modelo responder"
  for i in $(seq 1 60); do
    if curl -s -m 2 -o /dev/null "http://localhost:$OLLAMA_PORT/api/tags"; then
      printf "\n"; ok "API respondendo em http://localhost:$OLLAMA_PORT"; return 0
    fi
    printf "."; sleep 1
  done
  printf "\n"; err "A API não respondeu. Veja os logs: docker logs $CONTAINER"; return 1
}

ensure_local_running() {
  require_docker || return 1
  local running
  running="$($DOCKER inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)"
  if [ "$running" = "true" ]; then ok "O modelo local já está rodando."; return 0; fi
  if [ -z "$running" ]; then
    err "O container do modelo local não existe. Use o menu 5 para criá-lo."
    return 1
  fi
  section "Subindo o modelo local"
  offer_stop_active || { err "Ainda há outro modelo ativo. Desligue-o (regra: só 1 por vez)."; return 1; }
  explain "O container já existe (está parado); 'docker start' o liga de novo, sem baixar nada."
  manual "docker start $CONTAINER"
  run "$DOCKER start $CONTAINER" || return 1
  wait_api
}

setup_local() {
  banner "🐳 Subir modelo LOCAL (Docker)"
  explain "Regra: só 1 modelo local por vez, sempre em container Docker (imagem oficial do Ollama)."
  collect_all; detect_pkg_mgr
  require_docker || return 1
  compute_budget

  section "Seu orçamento de memória"
  case "$MODE" in
    nvidia) ok "GPU NVIDIA no Docker: ~${FAST} GB de VRAM (até ~${SLOW} GB com offload para RAM)" ;;
    amd)    ok "GPU AMD (ROCm): ~${FAST} GB de VRAM (até ~${SLOW} GB com offload para RAM)" ;;
    *)      warn "Só CPU: ~${FAST} GB utilizáveis. Funciona, mas é lento." ;;
  esac
  if [ "$GPU_TYPE" = "nvidia" ] && [ "$GPU_IN_DOCKER" = 0 ]; then
    warn "Há GPU NVIDIA, mas o Docker não a enxerga. O menu 2 resolve (NVIDIA Container Toolkit)."
  fi
  [ "$GPU_TYPE" = "apple" ] && info "Mac: o Docker não acessa a GPU Apple, então roda em CPU."

  show_catalog
  best_model
  [ -n "$BEST_TAG" ] && info "Sugestão para sua máquina: $BEST_TAG"

  local sel tag need disk agent note
  read -r -p "  👉 Número do modelo (ou 'o' para outra tag, 0 cancela): " sel || exit 1
  case "$sel" in
    0|"") warn "Cancelado."; return 0 ;;
    o|O)
      ask_text "Tag do modelo (ex.: llama3.2:3b)" ""
      tag="$REPLY_TXT"; need=0; disk=0
      [ -z "$tag" ] && return 0 ;;
    *[!0-9]*) err "Opção inválida."; return 1 ;;
    *)
      if [ "$sel" -lt 1 ] || [ "$sel" -gt "${#MODELS[@]}" ]; then err "Número inválido."; return 1; fi
      IFS='|' read -r tag need disk agent note <<< "${MODELS[$((sel-1))]}" ;;
  esac

  if [ "$need" != 0 ]; then
    if ! fits "$need" "$SLOW"; then
      warn "Este modelo provavelmente NÃO cabe (precisa ~${need} GB, você tem ~${SLOW} GB)."
      ask_yn "Continuar mesmo assim?" n || return 0
    elif ! fits "$need" "$FAST"; then
      warn "Vai funcionar, mas devagar (parte do modelo ficará na RAM)."
    fi
  fi
  if [ "$disk" != 0 ] && lt "$DISK_GB" "$disk"; then
    warn "Disco livre (${DISK_GB} GB) menor que o tamanho do modelo (~${disk} GB)."
    ask_yn "Continuar mesmo assim?" n || return 0
  fi

  section "1/5 · Garantir que só um modelo local fique ativo"
  offer_stop_active || { err "Ainda há modelo ativo. Desligue-o para continuar (regra: 1 por vez)."; return 1; }
  if port_in_use "$OLLAMA_PORT"; then
    err "A porta $OLLAMA_PORT está ocupada por outro programa."
    manual "ss -ltnp | grep $OLLAMA_PORT     # ou: lsof -i :$OLLAMA_PORT"
    return 1
  fi

  section "2/5 · Preparar o container"
  if $DOCKER inspect "$CONTAINER" >/dev/null 2>&1; then
    explain "Já existe um container parado do assistente. Vou recriá-lo para aplicar o novo contexto/GPU. Os modelos já baixados ficam no volume '$VOLUME'."
    manual "docker rm $CONTAINER"
    run "$DOCKER rm $CONTAINER" || return 1
  else
    ok "Nenhum container anterior."
  fi

  local ctx=32768
  if [ "$need" != 0 ] && fits "$(calc "$need + 8")" "$FAST"; then ctx=65536; fi
  explain "O Claude Code envia prompts enormes (instruções + ferramentas + arquivos). Contexto pequeno faz o agente se perder; contexto grande consome mais memória."
  ask_text "Tamanho do contexto em tokens (32768 ou 65536 são bons)" "$ctx"
  case "$REPLY_TXT" in ""|*[!0-9]*) err "Valor inválido."; return 1 ;; esac
  ctx="$REPLY_TXT"

  section "3/5 · Criar e iniciar o container"
  local gpu_flag="" image="$OLLAMA_IMAGE" body
  case "$MODE" in
    nvidia) gpu_flag="--gpus=all" ;;
    amd)    gpu_flag="--device /dev/kfd --device /dev/dri"; image="$ROCM_IMAGE" ;;
  esac
  body="run -d --name $CONTAINER --label claude-llm=1 $gpu_flag --restart unless-stopped -p 127.0.0.1:$OLLAMA_PORT:11434 -v $VOLUME:/root/.ollama -e OLLAMA_CONTEXT_LENGTH=$ctx -e OLLAMA_MAX_LOADED_MODELS=1 -e OLLAMA_NUM_PARALLEL=1 -e OLLAMA_KEEP_ALIVE=30m $image"
  explain "-d roda em segundo plano; -p 127.0.0.1:... expõe a API só para sua máquina; -v guarda os modelos num volume (sobrevivem ao container); OLLAMA_MAX_LOADED_MODELS=1 garante um único modelo carregado."
  manual "docker $body"
  run "$DOCKER $body" || return 1
  wait_api || return 1

  section "4/5 · Baixar o modelo ($tag)"
  explain "'ollama pull' baixa os pesos do modelo para dentro do volume. Pode demorar bastante e ocupa vários GB."
  manual "docker exec -it $CONTAINER ollama pull $tag"
  run "$DOCKER exec -it $CONTAINER ollama pull $tag" || { err "Falha ao baixar. Confira a tag em https://ollama.com/library"; return 1; }
  manual "docker exec $CONTAINER ollama list"
  run "$DOCKER exec $CONTAINER ollama list"

  section "5/5 · Perfil do Claude Code"
  explain "Salvo as variáveis de ambiente que apontam o Claude Code para o seu modelo local. Só existe 1 perfil local; criar outro substitui este."
  {
    envline ANTHROPIC_BASE_URL "http://localhost:$OLLAMA_PORT"
    envline ANTHROPIC_AUTH_TOKEN "ollama"
    envline ANTHROPIC_API_KEY ""
    model_envs "$tag"
    envline CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC "1"
  } | write_profile "local" "local" "🐳 Local: $tag (Docker, contexto $ctx)"
  set_active "local"
  ok "Perfil 'local' criado e ativado: $PROFILES_DIR/local.env"
  manual "export ANTHROPIC_BASE_URL=http://localhost:$OLLAMA_PORT" \
         "export ANTHROPIC_AUTH_TOKEN=ollama" \
         "export ANTHROPIC_API_KEY=\"\"" \
         "export ANTHROPIC_MODEL=$tag" \
         "claude"
  install_wrapper
  info "Agora use o menu 8 para testar e o menu 9 para abrir o Claude Code (ou digite claude-llm)."
}

# ─────────────────────────────── Modelo EXTERNO ───────────────────────────────
add_external() {
  banner "☁️  Adicionar modelo EXTERNO"
  explain "Modelos externos rodam em servidores de terceiros (cobram por uso ou têm camada gratuita). Você pode cadastrar quantos quiser; o Docker não é usado aqui."
  echo "     1) Anthropic API (chave sk-ant-...)"
  echo "     2) OpenRouter (inclui modelos gratuitos)"
  echo "     3) Google Vertex AI"
  echo "     4) Amazon Bedrock"
  echo "     5) Outro endpoint compatível com Anthropic (LiteLLM, proxy próprio...)"
  echo "     0) Voltar"
  local c prov nick slug model key base proj region awsprof label
  read -r -p "  👉 Escolha: " c || exit 1
  case "$c" in
    1) prov="Anthropic API" ;;
    2) prov="OpenRouter" ;;
    3) prov="Vertex AI" ;;
    4) prov="Bedrock" ;;
    5) prov="Custom" ;;
    0|"") return 0 ;;
    *) err "Opção inválida."; return 1 ;;
  esac
  ask_text "Apelido para este perfil" "$(slugify "$prov")"
  nick="$(slugify "$REPLY_TXT")"; [ -z "$nick" ] && nick="externo"
  slug="ext-$nick"
  label="☁️ $prov ($nick)"
  if [ -f "$PROFILES_DIR/$slug.env" ]; then
    warn "Já existe o perfil '$slug'."
    ask_yn "Sobrescrever?" n || return 0
  fi

  case "$c" in
    1)
      explain "A API oficial da Anthropic é paga por uso. Crie a chave em https://console.anthropic.com. O Claude Code lê a chave da variável ANTHROPIC_API_KEY."
      ask_secret "Cole sua chave (não aparece na tela)"; key="$REPLY_TXT"
      [ -z "$key" ] && { err "Chave vazia."; return 1; }
      ask_text "Modelo (ENTER = padrão do Claude Code)" ""; model="$REPLY_TXT"
      {
        envline ANTHROPIC_API_KEY "$key"
        if [ -n "$model" ]; then model_envs "$model"; fi
      } | write_profile "$slug" "externo" "$label"
      manual "export ANTHROPIC_API_KEY=sk-ant-..." "claude"
      ;;
    2)
      explain "OpenRouter é um agregador de modelos com endpoint compatível com a API da Anthropic. Modelos terminando em ':free' não têm custo, mas têm limite de uso. A lista muda com frequência: veja https://openrouter.ai/models?max_price=0"
      ask_secret "Cole sua chave do OpenRouter (sk-or-...)"; key="$REPLY_TXT"
      [ -z "$key" ] && { err "Chave vazia."; return 1; }
      ask_text "Modelo" "qwen/qwen3-coder:free"; model="$REPLY_TXT"
      [ -z "$model" ] && { err "Modelo vazio."; return 1; }
      {
        envline ANTHROPIC_BASE_URL "https://openrouter.ai/api"
        envline ANTHROPIC_AUTH_TOKEN "$key"
        envline ANTHROPIC_API_KEY ""
        model_envs "$model"
      } | write_profile "$slug" "externo" "$label: $model"
      manual "export ANTHROPIC_BASE_URL=https://openrouter.ai/api" \
             "export ANTHROPIC_AUTH_TOKEN=sk-or-..." \
             "export ANTHROPIC_API_KEY=\"\"" \
             "export ANTHROPIC_MODEL=$model" \
             "claude"
      ;;
    3)
      explain "Usa sua conta Google Cloud: precisa de um projeto com Vertex AI e acesso aos modelos Claude, e de login via gcloud."
      command -v gcloud >/dev/null 2>&1 || warn "gcloud não encontrado. Instale em https://cloud.google.com/sdk"
      ask_text "ID do projeto Google Cloud" ""; proj="$REPLY_TXT"
      [ -z "$proj" ] && { err "Projeto vazio."; return 1; }
      ask_text "Região" "global"; region="$REPLY_TXT"
      ask_text "Modelo (opcional)" ""; model="$REPLY_TXT"
      {
        envline CLAUDE_CODE_USE_VERTEX "1"
        envline CLOUD_ML_REGION "$region"
        envline ANTHROPIC_VERTEX_PROJECT_ID "$proj"
        if [ -n "$model" ]; then model_envs "$model"; fi
      } | write_profile "$slug" "externo" "$label"
      manual "gcloud auth application-default login" \
             "export CLAUDE_CODE_USE_VERTEX=1" \
             "export CLOUD_ML_REGION=$region" \
             "export ANTHROPIC_VERTEX_PROJECT_ID=$proj" \
             "claude"
      info "Faça o login com: gcloud auth application-default login"
      ;;
    4)
      explain "Usa sua conta AWS com o Bedrock. Precisa de credenciais configuradas (aws configure) e acesso liberado aos modelos Claude."
      command -v aws >/dev/null 2>&1 || warn "AWS CLI não encontrado. Instale em https://aws.amazon.com/cli/"
      ask_text "Região AWS" "us-east-1"; region="$REPLY_TXT"
      ask_text "Perfil AWS (ENTER = padrão)" ""; awsprof="$REPLY_TXT"
      ask_text "Modelo/inference profile (opcional)" ""; model="$REPLY_TXT"
      {
        envline CLAUDE_CODE_USE_BEDROCK "1"
        envline AWS_REGION "$region"
        if [ -n "$awsprof" ]; then envline AWS_PROFILE "$awsprof"; fi
        if [ -n "$model" ]; then model_envs "$model"; fi
      } | write_profile "$slug" "externo" "$label"
      manual "aws configure" \
             "export CLAUDE_CODE_USE_BEDROCK=1" \
             "export AWS_REGION=$region" \
             "claude"
      ;;
    5)
      explain "Qualquer servidor que fale o formato da API da Anthropic (LiteLLM, proxy da empresa, etc.). Preciso do endereço base e do token."
      ask_text "URL base (ex.: http://localhost:4000)" ""; base="$REPLY_TXT"
      [ -z "$base" ] && { err "URL vazia."; return 1; }
      ask_secret "Token/chave (ENTER se não houver)"; key="$REPLY_TXT"
      ask_text "Modelo (opcional)" ""; model="$REPLY_TXT"
      {
        envline ANTHROPIC_BASE_URL "$base"
        envline ANTHROPIC_AUTH_TOKEN "${key:-none}"
        if [ -n "$model" ]; then model_envs "$model"; fi
      } | write_profile "$slug" "externo" "$label"
      manual "export ANTHROPIC_BASE_URL=$base" "export ANTHROPIC_AUTH_TOKEN=..." "claude"
      ;;
  esac

  ok "Perfil criado: $PROFILES_DIR/$slug.env (permissão 600: só você lê)"
  show_profile_file "$slug"
  ensure_wrapper
  if ask_yn "Ativar este perfil agora?" s; then
    set_active "$slug"
    ok "Perfil '$slug' ativado."
  fi
}

# ───────────────────────────── Menu 4: desligar ───────────────────────────────
stop_active() {
  banner "🛑 Desligar modelo ativo"
  collect_docker
  if [ "$DOCKER_STATE" = "perm" ]; then require_docker; fi
  offer_stop_active
  if [ $? -eq 0 ]; then ok "Máquina livre: nenhum modelo local ativo."; fi
}

# ───────────────────────────── Menu 7: gerenciar perfis ───────────────────────
manage_profiles() {
  banner "🗂️  Gerenciar perfis"
  explain "Cada perfil é um arquivo com as variáveis de ambiente de um modelo. O perfil ativo é o que o comando claude-llm usa. Externos: quantos quiser. Local: só 1."
  collect_docker
  show_profiles || return 0
  echo
  echo "     a) Ativar    v) Ver conteúdo    r) Remover    0) Voltar"
  local c slug type
  read -r -p "  👉 Escolha: " c || exit 1
  case "$c" in
    a|A)
      pick_profile "Qual ativar?" || return 0
      slug="${PF_SLUG[$PICK_IDX]}"
      type="$(profile_field "$slug" PROFILE_TYPE)"
      if [ "$type" = "local" ]; then
        ensure_local_running || return 1
      else
        scan_active_models
        if [ "${#AC_ID[@]}" -gt 0 ]; then
          info "Há um modelo local ligado. Ele não é necessário para um perfil externo; o menu 4 libera a memória."
        fi
      fi
      set_active "$slug"
      ok "Perfil ativo: ${PF_LABEL[$PICK_IDX]}"
      manual "echo $slug > $ACTIVE_FILE" "claude-llm --profile $slug     # ou use um perfil só nesta execução"
      ;;
    v|V)
      pick_profile "Qual ver?" || return 0
      slug="${PF_SLUG[$PICK_IDX]}"
      explain "Chaves e tokens aparecem mascarados."
      manual "cat $PROFILES_DIR/$slug.env"
      show_profile_file "$slug"
      ;;
    r|R)
      pick_profile "Qual remover?" || return 0
      slug="${PF_SLUG[$PICK_IDX]}"
      ask_yn "Remover o perfil '${PF_LABEL[$PICK_IDX]}'?" n || return 0
      manual "rm $PROFILES_DIR/$slug.env"
      run "rm -f \"$PROFILES_DIR/$slug.env\""
      if [ "$slug" = "local" ] && require_docker; then
        if $DOCKER inspect "$CONTAINER" >/dev/null 2>&1; then
          if ask_yn "Remover também o container do modelo local?" s; then
            manual "docker rm -f $CONTAINER"
            run "$DOCKER rm -f $CONTAINER"
          fi
        fi
        if $DOCKER volume inspect "$VOLUME" >/dev/null 2>&1; then
          if ask_yn "Apagar também os modelos baixados (volume, libera disco)?" n; then
            manual "docker volume rm $VOLUME"
            run "$DOCKER volume rm $VOLUME"
          fi
        fi
      fi
      ;;
    *) return 0 ;;
  esac
}

# ───────────────────────────── Menu 8: testar ─────────────────────────────────
test_active() {
  banner "🧪 Testar o perfil ativo"
  local slug type base model body
  slug="$(active_slug)"
  if [ -z "$slug" ]; then err "Nenhum perfil ativo. Use os menus 5, 6 ou 7."; return 1; fi
  type="$(profile_field "$slug" PROFILE_TYPE)"
  ok "Perfil: $(profile_field "$slug" PROFILE_LABEL)"

  if [ "$type" = "local" ]; then
    base="$(profile_field "$slug" ANTHROPIC_BASE_URL)"
    model="$(profile_field "$slug" ANTHROPIC_MODEL)"
    section "1/3 · O container está rodando?"
    collect_docker
    require_docker || return 1
    explain "Confiro se o container do modelo está de pé."
    manual "docker ps --filter name=$CONTAINER"
    run "$DOCKER ps --filter name=$CONTAINER"
    section "2/3 · A API responde?"
    explain "A rota /api/tags lista os modelos baixados."
    manual "curl $base/api/tags"
    run "curl -s -m 5 $base/api/tags; echo" || { err "Sem resposta. Use o menu 7 → ativar."; return 1; }
    section "3/3 · O modelo responde no formato da Anthropic?"
    explain "É exatamente o formato que o Claude Code usa (/v1/messages). Na primeira chamada o modelo precisa carregar na memória, então pode demorar."
    body="{\"model\":\"$model\",\"max_tokens\":32,\"messages\":[{\"role\":\"user\",\"content\":\"Diga apenas: ok\"}]}"
    manual "curl $base/v1/messages -H 'content-type: application/json' -H 'x-api-key: ollama' -H 'anthropic-version: 2023-06-01' -d '$body'"
    run "curl -s -m 300 $base/v1/messages -H 'content-type: application/json' -H 'x-api-key: ollama' -H 'anthropic-version: 2023-06-01' -d '$body'; echo"
  fi

  section "Teste real com o Claude Code"
  collect_claude
  if [ "$HAS_CLAUDE" = 0 ]; then warn "Claude Code não instalado (menu 3)."; return 0; fi
  ensure_wrapper
  explain "O modo -p (print) envia uma pergunta, imprime a resposta e sai. Com modelo local em CPU isso pode levar minutos, pois o Claude Code envia um prompt grande."
  manual "claude-llm -p 'Responda apenas com a palavra: ok'"
  if ask_yn "Rodar este teste agora?" s; then
    "$WRAPPER" -p "Responda apenas com a palavra: ok"
    echo
  fi
}

# ───────────────────────────── Menu 9: abrir Claude Code ──────────────────────
launch_claude() {
  banner "🚀 Abrir o Claude Code"
  collect_claude
  if [ "$HAS_CLAUDE" = 0 ]; then err "Claude Code não instalado. Use o menu 3."; return 1; fi
  local slug dir args=""
  slug="$(active_slug)"
  if [ -z "$slug" ]; then err "Nenhum perfil ativo. Use os menus 5, 6 ou 7."; return 1; fi
  if ! ask_yn "Usar o perfil ativo ($(profile_field "$slug" PROFILE_LABEL))?" s; then
    pick_profile "Qual perfil usar nesta sessão?" || return 0
    slug="${PF_SLUG[$PICK_IDX]}"
    args="--profile $slug"
  fi
  ask_text "Pasta do projeto" "$PWD"
  dir="$REPLY_TXT"
  if [ ! -d "$dir" ]; then err "Pasta não existe: $dir"; return 1; fi
  ensure_wrapper
  explain "O claude-llm carrega as variáveis do perfil e chama o 'claude' dentro da pasta escolhida. Para sair do Claude Code, digite /exit."
  manual "cd $dir" "claude-llm $args"
  ( cd "$dir" && "$WRAPPER" $args )
}

# ───────────────────────────── Menu principal ─────────────────────────────────
main_menu() {
  local c act lbl
  while true; do
    banner "🚀 Claude Code + LLMs — Assistente v$VERSION"
    act="$(active_slug)"
    if [ -n "$act" ]; then lbl="$(profile_field "$act" PROFILE_LABEL)"; else lbl="nenhum"; fi
    printf "  🎯 Perfil ativo: %s\n\n" "$lbl"
    echo "     1) 🩺 Diagnóstico completo da máquina"
    echo "     2) 🔧 Instalar/corrigir requisitos (Docker, GPU, ferramentas)"
    echo "     3) 🤖 Instalar/atualizar o Claude Code"
    echo "     4) 🛑 Desligar modelo ativo"
    echo "     5) 🐳 Subir modelo LOCAL (Docker, 1 por vez)"
    echo "     6) ☁️  Adicionar modelo EXTERNO (quantos quiser)"
    echo "     7) 🗂️  Gerenciar perfis (ativar, ver, remover)"
    echo "     8) 🧪 Testar o perfil ativo"
    echo "     9) 🚀 Abrir o Claude Code"
    echo "     0) 👋 Sair"
    echo
    read -r -p "  👉 Escolha: " c || { echo; exit 0; }
    case "$c" in
      1) preflight ;;
      2) fix_requirements ;;
      3) install_claude ;;
      4) stop_active ;;
      5) setup_local ;;
      6) add_external ;;
      7) manage_profiles ;;
      8) test_active ;;
      9) launch_claude ;;
      0|q|Q) echo "  👋 Até mais!"; exit 0 ;;
      *) warn "Opção inválida." ;;
    esac
    echo
    pause
  done
}

# ─────────────────────────────── Início ───────────────────────────────────────
mkdir -p "$PROFILES_DIR" 2>/dev/null
collect_all
detect_pkg_mgr
main_menu

