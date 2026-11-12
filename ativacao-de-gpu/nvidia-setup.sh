#!/usr/bin/env bash
# =============================================================================
# nvidia-setup.sh - Diagnóstico e ativação de GPU NVIDIA GeForce no Ubuntu
# Uso: chmod +x nvidia-setup.sh && ./nvidia-setup.sh
# (execute como usuário normal; o script chama sudo quando necessário)
# =============================================================================

set -u

TS="$(date +%Y%m%d-%H%M%S)"
LOG="$HOME/nvidia-setup-$TS.log"
BACKUP_DIR="$HOME/nvidia-backup-$TS"
REBOOT_NEEDED=0

# Cores
VERM=$'\e[31m'; VERD=$'\e[32m'; AMAR=$'\e[33m'; AZUL=$'\e[34m'; NEG=$'\e[1m'; RESET=$'\e[0m'

# ---------------------------- Funções utilitárias ----------------------------
log()   { echo "[$(date +%H:%M:%S)] $*" >> "$LOG"; }
info()  { echo -e "${AZUL}[INFO]${RESET} $*"; log "INFO: $*"; }
ok()    { echo -e "${VERD}[ OK ]${RESET} $*"; log "OK: $*"; }
aviso() { echo -e "${AMAR}[AVISO]${RESET} $*"; log "AVISO: $*"; }
erro()  { echo -e "${VERM}[ERRO]${RESET} $*"; log "ERRO: $*"; }
titulo(){ echo -e "\n${NEG}=== $* ===${RESET}"; }

riscos() {
    echo -e "\n${AMAR}${NEG}RISCOS DESTA AÇÃO:${RESET}"
    printf "  - %s\n" "$@"
    echo
}

confirmar() {
    local r
    read -r -p "$1 [s/N]: " r
    [[ "${r,,}" == "s" || "${r,,}" == "sim" ]]
}

confirmar_forte() {
    local r
    read -r -p "$1 Digite SIM (em maiúsculas) para continuar: " r
    [[ "$r" == "SIM" ]]
}

pausa() { read -r -p "Pressione ENTER para continuar..." _; }

tem_cmd() { command -v "$1" >/dev/null 2>&1; }

instalar_se_faltar() {
    # $1 = comando, $2 = pacote
    if ! tem_cmd "$1"; then
        aviso "O comando '$1' não existe (pacote '$2')."
        if confirmar "Instalar '$2' agora?"; then
            sudo apt-get update -qq && sudo apt-get install -y "$2"
        else
            return 1
        fi
    fi
}

fazer_backup() {
    [[ -d "$BACKUP_DIR" ]] && return 0
    info "Criando backup de configurações em: $BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
    dpkg --get-selections > "$BACKUP_DIR/pacotes-instalados.txt"
    uname -r > "$BACKUP_DIR/kernel.txt"
    sudo cp -a /etc/modprobe.d "$BACKUP_DIR/" 2>/dev/null
    sudo cp -a /etc/default/grub "$BACKUP_DIR/" 2>/dev/null
    sudo cp -a /etc/X11 "$BACKUP_DIR/" 2>/dev/null
    sudo chown -R "$USER": "$BACKUP_DIR" 2>/dev/null
    ok "Backup concluído."
}

# ---------------------------- Estado global ----------------------------------
TEM_NVIDIA=0; SB_ON=0; SB_DESCONHECIDO=0; NOUVEAU=0; DRIVER_OK=0; HIBRIDA=0

# ---------------------------- 1. Diagnóstico ---------------------------------
diagnostico() {
    titulo "DIAGNÓSTICO DA GPU NVIDIA"
    TEM_NVIDIA=0; SB_ON=0; SB_DESCONHECIDO=0; NOUVEAU=0; DRIVER_OK=0; HIBRIDA=0

    info "Sistema: $(. /etc/os-release && echo "$PRETTY_NAME") | Kernel: $(uname -r)"
    info "Sessão gráfica: ${XDG_SESSION_TYPE:-desconhecida}"

    titulo "Hardware de vídeo detectado"
    lspci -nn | grep -Ei 'vga|3d controller|display controller' || aviso "Nenhum controlador de vídeo listado."

    if lspci | grep -Ei 'vga|3d controller|display controller' | grep -qi nvidia; then
        TEM_NVIDIA=1
        ok "Placa NVIDIA encontrada no barramento PCI."
    else
        erro "Nenhuma GPU NVIDIA detectada pelo lspci."
        aviso "Possíveis causas: GPU desativada na BIOS/UEFI, falha de hardware, eGPU/VM sem passthrough."
        return 1
    fi

    local qtd
    qtd=$(lspci | grep -Eic 'vga|3d controller|display controller')
    if (( qtd > 1 )); then
        HIBRIDA=1
        info "Mais de uma GPU detectada (provável notebook com gráficos híbridos)."
    fi

    titulo "Secure Boot"
    if tem_cmd mokutil; then
        if mokutil --sb-state 2>&1 | grep -qi 'enabled'; then
            SB_ON=1
            aviso "Secure Boot ATIVADO. Módulos NVIDIA precisam ser assinados (MOK)."
        else
            ok "Secure Boot desativado (ou não aplicável)."
        fi
    else
        SB_DESCONHECIDO=1
        aviso "mokutil não instalado; não foi possível verificar o Secure Boot."
    fi

    titulo "Drivers e módulos do kernel"
    if lsmod | grep -q '^nouveau'; then
        NOUVEAU=1
        aviso "Driver livre 'nouveau' em uso (sem aceleração total da NVIDIA)."
    fi
    if lsmod | grep -q '^nvidia'; then
        ok "Módulo 'nvidia' carregado no kernel."
    else
        aviso "Módulo 'nvidia' NÃO está carregado."
    fi

    if tem_cmd nvidia-smi && nvidia-smi >/dev/null 2>&1; then
        DRIVER_OK=1
        ok "nvidia-smi funcionando:"
        nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader
    else
        aviso "nvidia-smi ausente ou falhando (driver não está operacional)."
    fi

    titulo "Pacotes NVIDIA instalados"
    local pacotes
    pacotes=$(dpkg -l 2>/dev/null | awk '/^ii/ && $2 ~ /^(nvidia-driver|nvidia-dkms|nvidia-kernel|nvidia-utils)/ {print "  " $2 " " $3}')
    [[ -n "$pacotes" ]] && echo "$pacotes" || info "Nenhum pacote de driver NVIDIA instalado."

    titulo "Cabeçalhos do kernel e DKMS"
    if dpkg -s "linux-headers-$(uname -r)" >/dev/null 2>&1; then
        ok "Headers do kernel atual instalados."
    else
        aviso "Headers de $(uname -r) ausentes (necessários para compilar o módulo via DKMS)."
    fi
    tem_cmd dkms && { dkms status 2>/dev/null | grep -i nvidia || info "Sem módulos NVIDIA no DKMS."; }

    titulo "Modo PRIME (gráficos híbridos)"
    if tem_cmd prime-select; then
        info "Modo atual: $(prime-select query 2>/dev/null)"
    else
        info "prime-select não instalado (relevante apenas em notebooks híbridos)."
    fi

    titulo "Drivers sugeridos pelo Ubuntu"
    if tem_cmd ubuntu-drivers; then
        ubuntu-drivers devices 2>/dev/null | grep -E 'driver|model' || info "Nenhuma sugestão disponível."
    else
        aviso "ubuntu-drivers não instalado (pacote ubuntu-drivers-common)."
    fi

    titulo "Mensagens relevantes do kernel"
    sudo dmesg 2>/dev/null | grep -iE 'nvidia|nouveau' \
        | grep -iE 'fail|error|reject|denied|taint|verification|firmware' | tail -n 8 \
        || true

    titulo "RESUMO"
    if (( DRIVER_OK )); then
        ok "Sua GPU NVIDIA está ATIVA e funcionando. Nada a fazer."
    else
        aviso "GPU detectada, mas o driver proprietário NÃO está operacional."
        (( NOUVEAU )) && info "-> 'nouveau' está ocupando a GPU; o driver proprietário resolve."
        (( SB_ON )) && info "-> Secure Boot ativo: será preciso registrar a chave MOK (opção 4)."
        info "-> Sugestão: use a opção 2 (instalar driver recomendado)."
    fi
    log "Diagnóstico concluído. DRIVER_OK=$DRIVER_OK SB_ON=$SB_ON NOUVEAU=$NOUVEAU"
}

# ---------------------------- 2/3. Instalar driver ---------------------------
instalar_pacote_driver() {
    local pkg="$1"

    riscos \
      "Será baixado de centenas de MB até cerca de 1 GB de pacotes." \
      "O initramfs será regenerado e o 'nouveau' será colocado em blacklist." \
      "Um reboot é obrigatório; se algo falhar, pode haver TELA PRETA ou loop de login." \
      "Com Secure Boot ativo, o driver não carrega sem registrar a chave MOK (uma senha temporária será pedida)." \
      "Em notebooks híbridos, o consumo de bateria e o comportamento de monitores externos podem mudar." \
      "Interromper a instalação no meio pode deixar o apt/dpkg quebrado." \
      "Rollback: remover o driver (opção 6) e reiniciar volta ao 'nouveau'. Um backup será feito antes."

    if (( SB_ON )); then
        aviso "Secure Boot está ATIVO. Durante a instalação, defina uma senha simples e anote-a."
        aviso "No próximo boot, aparecerá uma tela azul (MOK Manager): Enroll MOK > Continue > Yes > senha > Reboot."
    fi

    confirmar_forte "Instalar '$pkg'?" || { info "Operação cancelada."; return 1; }

    fazer_backup
    info "Atualizando índices e instalando headers + driver..."
    sudo apt-get update || { erro "Falha no apt update. Verifique sua conexão."; return 1; }
    sudo apt-get install -y "linux-headers-$(uname -r)" "$pkg" || {
        erro "Falha na instalação. Veja a saída acima e o log: $LOG"
        return 1
    }
    ok "Driver '$pkg' instalado."
    REBOOT_NEEDED=1
}

instalar_recomendado() {
    titulo "INSTALAR DRIVER RECOMENDADO"
    instalar_se_faltar ubuntu-drivers ubuntu-drivers-common || return 1

    local rec
    rec=$(ubuntu-drivers devices 2>/dev/null | awk '/recommended/ {print $3; exit}')
    if [[ -z "$rec" ]]; then
        erro "O Ubuntu não indicou um driver recomendado para sua GPU."
        aviso "Use a opção 3 para escolher uma versão manualmente."
        return 1
    fi
    info "Driver recomendado: $rec"
    instalar_pacote_driver "$rec"
}

instalar_especifico() {
    titulo "INSTALAR VERSÃO ESPECÍFICA"
    info "Versões disponíveis nos repositórios:"
    apt-cache search --names-only '^nvidia-driver-[0-9]+(-open)?$' | sort -V | awk '{print "  " $1}'
    echo
    aviso "Versões muito antigas podem não suportar sua GPU; muito novas podem ser instáveis."
    local pkg
    read -r -p "Digite o nome do pacote (ex.: nvidia-driver-550) ou ENTER para cancelar: " pkg
    [[ -z "$pkg" ]] && return 0
    if [[ ! "$pkg" =~ ^nvidia-driver-[0-9]+(-open)?$ ]] || ! apt-cache show "$pkg" >/dev/null 2>&1; then
        erro "Pacote inválido ou inexistente: $pkg"
        return 1
    fi
    instalar_pacote_driver "$pkg"
}

# ---------------------------- 4. Secure Boot / MOK ---------------------------
secure_boot_mok() {
    titulo "SECURE BOOT / REGISTRO DE CHAVE MOK"
    instalar_se_faltar mokutil mokutil || return 1

    if ! mokutil --sb-state 2>&1 | grep -qi enabled; then
        ok "Secure Boot não está ativo; nada a fazer aqui."
        return 0
    fi

    info "Você tem duas opções:"
    echo "  A) Registrar a chave MOK do Ubuntu (recomendado, mantém a segurança)."
    echo "  B) Desativar o Secure Boot na BIOS/UEFI (manual, este script não faz isso)."

    local chave="/var/lib/shim-signed/mok/MOK.der"
    if [[ ! -f "$chave" ]]; then
        aviso "Chave $chave não encontrada. Ela é criada ao instalar o driver via DKMS."
        aviso "Instale o driver primeiro (opção 2 ou 3)."
        return 1
    fi

    riscos \
      "Você definirá uma senha temporária; se errar ou esquecer, será preciso repetir o processo." \
      "No reboot, a tela azul do MOK Manager aparece apenas uma vez; se ignorada, o driver continua sem carregar." \
      "Registrar uma chave diminui um pouco a proteção do Secure Boot, pois confia em módulos assinados por ela." \
      "Desativar o Secure Boot (opção B) é mais arriscado e pode impactar dual boot com Windows (BitLocker pode pedir a chave de recuperação)."

    confirmar_forte "Registrar a chave MOK agora?" || { info "Cancelado."; return 1; }
    sudo mokutil --import "$chave" && {
        ok "Chave agendada. No próximo boot: Enroll MOK > Continue > Yes > senha > Reboot."
        REBOOT_NEEDED=1
    }
}

# ---------------------------- 5. Modo PRIME ----------------------------------
modo_prime() {
    titulo "MODO DA GPU (PRIME)"
    instalar_se_faltar prime-select nvidia-prime || return 1

    info "Modo atual: $(prime-select query 2>/dev/null)"
    echo "  nvidia     -> usa só a NVIDIA (mais desempenho, mais bateria gasta)"
    echo "  on-demand  -> usa a integrada e a NVIDIA sob demanda (equilíbrio)"
    echo "  intel      -> desliga a NVIDIA (economia máxima)"

    riscos \
      "Exige logout/reboot para ter efeito." \
      "Modo 'nvidia': maior consumo e calor em notebooks." \
      "Modo 'intel': a GPU NVIDIA fica indisponível (jogos/CUDA não a usarão)." \
      "Se o driver NVIDIA não estiver funcional e você escolher 'nvidia', pode ocorrer TELA PRETA no login." \
      "Algumas saídas de vídeo (HDMI/DP) só funcionam ligadas à NVIDIA em certos notebooks."

    local m
    PS3="Escolha o modo: "
    select m in nvidia on-demand intel cancelar; do
        case "$m" in
            nvidia|on-demand|intel)
                confirmar_forte "Alterar para '$m'?" || { info "Cancelado."; return 1; }
                fazer_backup
                sudo prime-select "$m" && { ok "Modo alterado para '$m'."; REBOOT_NEEDED=1; }
                break ;;
            cancelar) info "Cancelado."; break ;;
            *) echo "Opção inválida." ;;
        esac
    done
}

# ---------------------------- 6. Remover drivers -----------------------------
remover_drivers() {
    titulo "REMOVER DRIVERS NVIDIA (REINSTALAÇÃO LIMPA)"
    riscos \
      "Todos os pacotes nvidia-* e libnvidia-* serão REMOVIDOS com purge." \
      "Ao reiniciar, o sistema usará o 'nouveau' ou vídeo básico (resolução e desempenho reduzidos)." \
      "Aplicações que dependem de CUDA, NVENC ou do driver proprietário deixarão de funcionar." \
      "Se esta for sua única GPU, a interface gráfica pode subir em resolução baixa." \
      "O apt mostrará a lista de pacotes removidos; leia com atenção, pois dependências podem ser afetadas."

    confirmar_forte "Remover todos os drivers NVIDIA?" || { info "Cancelado."; return 1; }
    fazer_backup
    sudo apt-get remove --purge -y '^nvidia-.*' '^libnvidia-.*' '^xserver-xorg-video-nvidia.*' \
        && sudo apt-get autoremove -y \
        && { ok "Drivers removidos."; REBOOT_NEEDED=1; }
}

# ---------------------------- 7. nvidia-drm.modeset --------------------------
habilitar_modeset() {
    titulo "HABILITAR nvidia-drm.modeset=1"
    info "Necessário para Wayland e útil para evitar tearing e problemas com PRIME."
    local arq="/etc/modprobe.d/nvidia-drm-modeset.conf"

    riscos \
      "O initramfs será regenerado (update-initramfs); falha nessa etapa pode atrapalhar o boot." \
      "Em GPUs/drivers antigos, pode causar instabilidade em suspensão/retomada." \
      "Rollback: apagar $arq, rodar 'sudo update-initramfs -u' e reiniciar."

    confirmar_forte "Criar $arq e atualizar o initramfs?" || { info "Cancelado."; return 1; }
    fazer_backup
    echo "options nvidia-drm modeset=1" | sudo tee "$arq" >/dev/null
    sudo update-initramfs -u && { ok "modeset habilitado."; REBOOT_NEEDED=1; }
}

# ---------------------------- Reboot -----------------------------------------
oferecer_reboot() {
    if (( REBOOT_NEEDED )); then
        echo
        aviso "Foram feitas alterações que exigem reinício para valer."
        riscos "Salve seu trabalho antes: o computador reiniciará imediatamente."
        confirmar "Reiniciar agora?" && sudo reboot
    fi
}

# ---------------------------- Menu principal ---------------------------------
menu() {
    while true; do
        echo -e "\n${NEG}========== ATIVAÇÃO DE GPU NVIDIA ==========${RESET}"
        echo " 1) Diagnóstico completo (somente leitura)"
        echo " 2) Instalar driver recomendado pelo Ubuntu"
        echo " 3) Instalar uma versão específica do driver"
        echo " 4) Secure Boot: registrar chave MOK"
        echo " 5) Alternar modo da GPU (PRIME, notebooks híbridos)"
        echo " 6) Remover drivers NVIDIA (reinstalação limpa)"
        echo " 7) Habilitar nvidia-drm.modeset=1"
        echo " 0) Sair"
        read -r -p "Escolha: " op
        case "$op" in
            1) diagnostico; pausa ;;
            2) instalar_recomendado; pausa ;;
            3) instalar_especifico; pausa ;;
            4) secure_boot_mok; pausa ;;
            5) modo_prime; pausa ;;
            6) remover_drivers; pausa ;;
            7) habilitar_modeset; pausa ;;
            0) break ;;
            *) echo "Opção inválida." ;;
        esac
    done
}

# ---------------------------- Início -----------------------------------------
if [[ $EUID -eq 0 ]]; then
    erro "Não execute como root. Rode como usuário normal; o script usa sudo quando preciso."
    exit 1
fi
if ! grep -qi ubuntu /etc/os-release; then
    aviso "Este script foi feito para Ubuntu; sua distro pode se comportar diferente."
    confirmar "Continuar mesmo assim?" || exit 1
fi

info "Log desta sessão: $LOG"
sudo -v || { erro "É necessário ter permissão de sudo."; exit 1; }

diagnostico
menu
oferecer_reboot
info "Finalizado. Log salvo em: $LOG"