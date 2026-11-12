#!/usr/bin/env bash
# diagnostico-llm.sh
# Diagnostica o hardware e sugere modelos locais (via Ollama) para usar com o Claude Code.
# Funciona em Linux e macOS. No Windows, rode dentro do WSL.

set -u

OS="$(uname -s)"
ARCH="$(uname -m)"

if [ "$OS" != "Linux" ] && [ "$OS" != "Darwin" ]; then
  echo "Sistema não suportado por este script ($OS). No Windows, use o WSL."
  exit 1
fi

# ---------- funções auxiliares ----------
fits()     { awk -v need="$1" -v have="$2" 'BEGIN { exit !(need <= have) }'; }
kb_to_gb() { awk -v kb="$1" 'BEGIN { printf "%.1f", kb/1024/1024 }'; }
calc()     { awk "BEGIN { printf \"%.1f\", $1 }"; }

# ---------- coleta de informações ----------
RAM_KB=0
CPU_NAME="desconhecida"
CORES=1
GPU_TYPE="none"          # none | nvidia | apple | amd | other
GPU_NAME="nenhuma detectada"
VRAM_GB=0
AVX2="n/a"

if [ "$OS" = "Darwin" ]; then
  RAM_KB=$(( $(sysctl -n hw.memsize) / 1024 ))
  CPU_NAME=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "desconhecida")
  CORES=$(sysctl -n hw.ncpu)
  if [ "$ARCH" = "arm64" ]; then
    GPU_TYPE="apple"
    GPU_NAME="Apple Silicon (memória unificada)"
  fi
else
  RAM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
  CPU_NAME=$(lscpu 2>/dev/null | awk -F: '/Model name/ {sub(/^[ \t]+/,"",$2); print $2; exit}')
  if [ -z "$CPU_NAME" ]; then
    CPU_NAME=$(awk -F: '/model name/ {sub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo)
  fi
  CORES=$(nproc)
  if grep -qi avx2 /proc/cpuinfo 2>/dev/null; then AVX2="sim"; else AVX2="não"; fi

  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    GPU_TYPE="nvidia"
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n1)
    GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l)
    [ "$GPU_COUNT" -gt 1 ] && GPU_NAME="$GPU_NAME (x$GPU_COUNT)"
    VRAM_MIB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | awk '{s+=$1} END {print s}')
    VRAM_GB=$(awk -v m="$VRAM_MIB" 'BEGIN { printf "%.1f", m/1024 }')
  elif command -v lspci >/dev/null 2>&1; then
    GPU_LINE=$(lspci 2>/dev/null | grep -Ei 'vga|3d|display' | head -n1)
    if [ -n "$GPU_LINE" ]; then
      GPU_NAME=$(echo "$GPU_LINE" | sed 's/^[^:]*: //')
      if echo "$GPU_LINE" | grep -Eqi 'amd|radeon'; then GPU_TYPE="amd"; else GPU_TYPE="other"; fi
    fi
  fi
fi

RAM_GB=$(kb_to_gb "$RAM_KB")
DISK_KB=$(df -Pk "$HOME" | awk 'NR==2 {print $4}')
DISK_GB=$(kb_to_gb "$DISK_KB")

# ---------- orçamento de memória para o modelo ----------
# FAST = memória onde o modelo roda "bem"; SLOW = limite com offload para RAM (mais lento)
case "$GPU_TYPE" in
  nvidia)
    FAST="$VRAM_GB"
    SLOW=$(calc "$VRAM_GB + $RAM_GB * 0.6")
    LABEL_OK="RODA BEM (na GPU)"
    ;;
  apple)
    FAST=$(calc "$RAM_GB * 0.7")
    SLOW="$FAST"
    LABEL_OK="RODA BEM (GPU Apple)"
    ;;
  *)
    FAST=$(calc "$RAM_GB * 0.6")
    SLOW="$FAST"
    LABEL_OK="RODA (só CPU, lento)"
    ;;
esac

# ---------- relatório de hardware ----------
echo "=============================================="
echo " DIAGNÓSTICO PARA LLMs LOCAIS"
echo "=============================================="
echo "Sistema ......: $OS ($ARCH)"
echo "CPU ..........: $CPU_NAME ($CORES threads, AVX2: $AVX2)"
echo "RAM ..........: ${RAM_GB} GB"
echo "GPU ..........: $GPU_NAME"
[ "$GPU_TYPE" = "nvidia" ] && echo "VRAM .........: ${VRAM_GB} GB"
echo "Disco livre ..: ${DISK_GB} GB (em \$HOME)"
echo "Memória útil p/ modelo: ~${FAST} GB (rápido) / ~${SLOW} GB (com offload)"
echo

if [ "$GPU_TYPE" = "amd" ] || [ "$GPU_TYPE" = "other" ]; then
  echo "AVISO: GPU detectada, mas sem VRAM mensurável por este script."
  echo "       Estou considerando apenas CPU + RAM. Com ROCm/Vulkan pode ser melhor."
  echo
fi

if fits "$DISK_GB" 30; then
  echo "AVISO: pouco espaço em disco. Modelos médios ocupam de 5 a 20 GB cada."
  echo
fi

# ---------- tabela de modelos ----------
# formato: tag Ollama | memória necessária (GB, Q4 + contexto) | serve como agente? | nota
MODELS=(
  "qwen2.5-coder:3b|4|n|Muito fraco como agente, só para testar a instalação"
  "qwen2.5-coder:7b|7|n|Bom para completar código, limitado como agente"
  "qwen3:8b|8|y|Entrada razoável para tool calling"
  "qwen2.5-coder:14b|12|y|Já aguenta tarefas simples de agente"
  "gpt-oss:20b|16|y|Bom em raciocínio e ferramentas"
  "devstral:24b|18|y|Focado em agentes de código"
  "qwen3-coder:30b|24|y|Melhor custo-benefício para o Claude Code"
  "gpt-oss:120b|80|y|Muito capaz, exige máquina grande"
)

BEST=""
printf "%-22s %-8s %-24s %s\n" "MODELO" "PRECISA" "STATUS" "OBSERVAÇÃO"
printf "%-22s %-8s %-24s %s\n" "------" "-------" "------" "----------"

for m in "${MODELS[@]}"; do
  IFS='|' read -r tag need agent note <<< "$m"
  if fits "$need" "$FAST"; then
    status="$LABEL_OK"
    [ "$agent" = "y" ] && BEST="$tag"
  elif fits "$need" "$SLOW"; then
    status="RODA LENTO (usa RAM)"
  else
    status="NÃO CABE"
  fi
  printf "%-22s %-8s %-24s %s\n" "$tag" "${need} GB" "$status" "$note"
done

echo

# ---------- recomendação ----------
if fits 24 "$FAST"; then CTX=65536; else CTX=32768; fi

if [ -z "$BEST" ]; then
  echo "RESULTADO: sua máquina é limitada para rodar um agente local com qualidade."
  echo "Alternativas gratuitas: modelos free do OpenRouter (via LiteLLM), Gemini CLI,"
  echo "Qwen Code ou OpenCode com camada gratuita."
else
  echo "RECOMENDAÇÃO: $BEST"
  echo
  if ! command -v ollama >/dev/null 2>&1; then
    echo "O Ollama não foi encontrado. Instale em https://ollama.com antes de continuar."
    echo
  fi
  echo "Passos sugeridos:"
  echo "  OLLAMA_CONTEXT_LENGTH=$CTX ollama serve"
  echo "  ollama pull $BEST"
  echo "  export ANTHROPIC_BASE_URL=http://localhost:11434"
  echo "  export ANTHROPIC_AUTH_TOKEN=ollama"
  echo "  export ANTHROPIC_API_KEY=\"\""
  echo "  claude --model $BEST"
fi

echo
echo "Obs.: valores são estimativas para quantização Q4. Tags e tamanhos mudam com o tempo,"
echo "confira em https://ollama.com/library."