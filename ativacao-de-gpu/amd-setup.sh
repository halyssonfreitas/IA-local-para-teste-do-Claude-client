#!/usr/bin/env bash
# =============================================================================
# amd-setup.sh - Diagnóstico e ativação de GPU AMD Radeon no Ubuntu
# Uso: chmod +x amd-setup.sh && ./amd-setup.sh
# (execute como usuário normal; o script chama sudo quando necessário)
# =============================================================================

set -u

TS="$(date +%Y%m%d-%H%M%S)"
LOG="$HOME/amd-setup-$TS.log"
BACKUP_DIR="$HOME/amd-backup-$TS"
REBOOT_NEEDED=0

GCN_PARAMS="amdgpu.si_support=1 amdgpu.cik_support=1 radeon.si_support=0 radeon.cik_support=0"
PPA="ppa:kisak/kisak-mesa"

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
    sudo cp -a /etc/default/grub.d "$BACKUP_DIR/" 2>/dev/null
    sudo cp -a /etc/apt/sources.list "$BACKUP_DIR/" 2>/dev/null
    sudo cp -a /etc/apt/sources.list.d "$BACKUP_DIR/" 2>/dev/null
    sudo chown -R "$USER": "$BACKUP_DIR" 2>/dev/null
    ok "Backup concluído."
}

# ---------------------------- Estado global ----------------------------------
TEM_AMD=0; DRIVER_EM_USO=""; LLVMPIPE=0; GL_TESTADO=0; NOMODESET=0; BLACKLIST_ARQS=""

# ---------------------------- 1. Diagnóstico ---------------------------------
diagnostico() {
    titulo "DIAGNÓSTICO DA GPU AMD"
    TEM_AMD=0; DRIVER_EM_USO=""; LLVMPIPE=0; GL_TESTADO=0; NOMODESET=0; BLACKLIST_ARQS=""

    info "Sistema: $(. /etc/os-release && echo "$PRETTY_NAME") | Kernel: $(uname -r)"
    info "Sessão gráfica: ${XDG_SESSION_TYPE:-desconhecida}"

    titulo "Hardware de vídeo detectado"
    lspci -nnk | grep -EiA3 'vga|3d controller|display controller' || aviso "Nenhum controlador de vídeo listado."

    if lspci -nn | grep -Ei 'vga|3d controller|display controller' | grep -q '|$$1002:'; then
        TEM_AMD=1
        ok "GPU AMD encontrada no barramento PCI."
    else
        erro "Nenhuma GPU AMD detectada pelo lspci."
        aviso "Possíveis causas: GPU desativada na BIOS/UEFI, falha de hardware, ou VM sem passthrough."
        return 1
    fi

    local qtd
    qtd=$(lspci | grep -Eic 'vga|3d controller|display controller')
    if (( qtd > 1 )); then
        info "Mais de uma GPU detectada (gráficos híbridos)."
        info "Para rodar um programa na GPU dedicada, use: DRI_PRIME=1 nome-do-programa"
    fi

    titulo "Driver em uso"
    local drivers
    drivers=$(lspci -nnk -d 1002: | awk '/^[0-9a-fA-F]/ {gpu = ($0 ~ /VGA|3D controller|Display controller/)} gpu && /Kernel driver in use/ {print $5}')
    if grep -qx amdgpu <<<"$drivers"; then
        DRIVER_EM_USO="amdgpu"
        ok "Driver 'amdgpu' (moderno, em código aberto) em uso."
    elif grep -qx radeon <<<"$drivers"; then
        DRIVER_EM_USO="radeon"
        aviso "Driver legado 'radeon' em uso (desempenho e recursos limitados)."
    else
        aviso "Nenhum driver de kernel ativo para a GPU AMD."
    fi
    lsmod | grep -E '^(amdgpu|radeon) ' || info "Nem 'amdgpu' nem 'radeon' estão carregados."

    titulo "Bloqueios conhecidos"
    if grep -qw nomodeset /proc/cmdline; then
        NOMODESET=1
        aviso "'nomodeset' está ativo neste boot: isso DESLIGA o driver de vídeo."
    else
        ok "'nomodeset' não está ativo."
    fi
    BLACKLIST_ARQS=$(grep -rEls '^[[:space:]]*(blacklist|install)[[:space:]]+amdgpu([[:space:]]|$)' /etc/modprobe.d /usr/lib/modprobe.d 2>/dev/null)
    if [[ -n "$BLACKLIST_ARQS" ]]; then
        aviso "O módulo 'amdgpu' está bloqueado em:"
        sed 's/^/  /' <<<"$BLACKLIST_ARQS"
    else
        ok "Nenhum bloqueio do 'amdgpu' em /etc/modprobe.d."
    fi

    titulo "Firmware"
    if compgen -G "/lib/firmware/amdgpu/*" >/dev/null || compgen -G "/usr/lib/firmware/amdgpu/*" >/dev/null; then
        ok "Arquivos de firmware da AMD presentes."
    else
        aviso "Firmware da AMD ausente (pacote linux-firmware). A GPU não inicializa sem ele."
    fi

    titulo "Secure Boot (informativo)"
    if tem_cmd mokutil; then
        mokutil --sb-state 2>&1 | head -n 1
        info "O driver 'amdgpu' do kernel já é assinado: normalmente NÃO exige registro de chave."
    else
        info "mokutil não instalado; verificação ignorada (não é um problema para o driver do kernel)."
    fi

    titulo "Aceleração 3D (OpenGL / Vulkan / vídeo)"
    if tem_cmd glxinfo; then
        local gl
        gl=$(glxinfo -B 2>/dev/null)
        if [[ -n "$gl" ]]; then
            GL_TESTADO=1
            echo "$gl" | grep -E 'renderer string|OpenGL version string' | sed 's/^/  /'
            grep -qi llvmpipe <<<"$gl" && LLVMPIPE=1
        else
            aviso "glxinfo sem dados (sem sessão gráfica? rodando por SSH?)."
        fi
    else
        info "glxinfo ausente (a opção 2 instala os utilitários)."
    fi
    if tem_cmd vulkaninfo; then
        vulkaninfo --summary 2>/dev/null | grep -E 'deviceName|driverName' | sed 's/^[[:space:]]*/  /'
    else
        info "vulkaninfo ausente (opção 2)."
    fi
    if tem_cmd vainfo; then
        vainfo 2>&1 | grep -E 'Driver version' | sed 's/^/  /'
    else
        info "vainfo ausente (opção 2)."
    fi

    titulo "Permissões de acesso à GPU"
    local g
    for g in video render; do
        if id -nG | tr ' ' '\n' | grep -qx "$g"; then
            ok "Você está no grupo '$g'."
        else
            aviso "Você não está no grupo '$g' (desktop comum funciona sem; ROCm/computação exige)."
        fi
    done

    titulo "ROCm (computação/IA)"
    if tem_cmd rocminfo; then
        rocminfo 2>/dev/null | grep -E 'Marketing Name' | head -n 3 | sed 's/^[[:space:]]*/  /'
    else
        info "ROCm não instalado (necessário só para computação/IA, não para jogos ou desktop)."
    fi

    titulo "Mensagens relevantes do kernel"
    sudo dmesg 2>/dev/null | grep -iE 'amdgpu|radeon' \
        | grep -iE 'fail|error|firmware|timeout|reset' | tail -n 8 \
        || true

    titulo "RESUMO"
    if [[ -z "$DRIVER_EM_USO" ]]; then
        aviso "GPU AMD detectada, mas SEM driver carregado."
        (( NOMODESET )) && info "-> 'nomodeset' ativo: use a opção 6."
        [[ -n "$BLACKLIST_ARQS" ]] && info "-> 'amdgpu' em blacklist: use a opção 6."
        info "-> Verifique o firmware e o Mesa (opção 3)."
        info "-> Se a GPU for muito recente, um kernel mais novo ajuda (opção 5)."
    elif [[ "$DRIVER_EM_USO" == "radeon" ]]; then
        aviso "Está usando o driver legado 'radeon'."
        info "-> Se a GPU for GCN 1.0/1.1 (ex.: HD 7000, R9 270/290), a opção 4 ativa o 'amdgpu'."
        info "-> Se for anterior (HD 6000 ou mais antiga), o 'amdgpu' não a suporta."
    elif (( LLVMPIPE )); then
        aviso "Driver 'amdgpu' carregado, mas o OpenGL roda por SOFTWARE (llvmpipe)."
        info "-> Reinstale o Mesa e o firmware (opção 3) e reinicie a sessão."
    elif (( ! GL_TESTADO )); then
        ok "Driver 'amdgpu' carregado. Instale os utilitários (opção 2) para validar a aceleração 3D."
    else
        ok "Sua GPU AMD está ATIVA e acelerando normalmente. Nada a fazer."
    fi
    log "Diagnóstico concluído. DRIVER=$DRIVER_EM_USO LLVMPIPE=$LLVMPIPE NOMODESET=$NOMODESET"
}

# ---------------------------- 2. Utilitários ---------------------------------
instalar_utilitarios() {
    titulo "INSTALAR UTILITÁRIOS DE DIAGNÓSTICO"
    local pkgs=(mesa-utils vulkan-tools vainfo radeontop)
    riscos \
      "Pacotes pequenos, do repositório oficial do Ubuntu." \
      "Nenhuma configuração do sistema é alterada." \
      "Rollback: sudo apt remove ${pkgs[*]}"
    confirmar "Instalar ${pkgs[*]}?" || { info "Cancelado."; return 1; }
    sudo apt-get update -qq && sudo apt-get install -y "${pkgs[@]}" && ok "Utilitários instalados."
}

# ---------------------------- 3. Mesa + firmware -----------------------------
instalar_mesa() {
    titulo "INSTALAR / REPARAR MESA E FIRMWARE"
    riscos \
      "Atualiza pacotes de gráficos usados pela interface inteira (Mesa, firmware)." \
      "Falha no meio do processo pode deixar o apt/dpkg quebrado e a interface instável." \
      "Pode ser necessário reiniciar a sessão ou o computador depois." \
      "Rollback: reinstalar as versões oficiais do Ubuntu (apt install --reinstall)."
    confirmar_forte "Continuar?" || { info "Cancelado."; return 1; }

    local flag=""
    confirmar "Forçar reinstalação dos pacotes (útil se houver arquivos corrompidos)?" && flag="--reinstall"

    fazer_backup
    sudo apt-get update || { erro "Falha no apt update."; return 1; }

    local pkgs=() p
    for p in linux-firmware libgl1-mesa-dri libglx-mesa0 libegl-mesa0 libgbm1 \
             mesa-vulkan-drivers mesa-va-drivers mesa-vdpau-drivers; do
        if apt-cache show "$p" >/dev/null 2>&1; then
            pkgs+=("$p")
        else
            aviso "Pacote indisponível nesta versão do Ubuntu, ignorado: $p"
        fi
    done
    # shellcheck disable=SC2086
    sudo apt-get install -y $flag "${pkgs[@]}" || { erro "Falha na instalação. Log: $LOG"; return 1; }
    ok "Mesa e firmware atualizados."
    REBOOT_NEEDED=1
}

# ---------------------------- 4. GPUs antigas (GCN 1.x) ----------------------
gcn_antigo() {
    titulo "AMDGPU PARA GPUs ANTIGAS (GCN 1.0 / 1.1)"
    info "GCN 1.0 (ex.: HD 7000, R7 240/250, R9 270/280) e GCN 1.1 (ex.: R7 260, R9 290/390)"
    info "usam o driver 'radeon' por padrão. O 'amdgpu' dá melhor desempenho e Vulkan."
    info "GPUs mais antigas (HD 6000 e anteriores) NÃO são suportadas pelo 'amdgpu'."

    if grep -qs 'amdgpu.si_support=1' /etc/default/grub; then
        info "Os parâmetros já estão presentes no GRUB."
        riscos \
          "Remove os parâmetros e o sistema volta ao driver 'radeon' no próximo boot." \
          "O GRUB será regenerado (update-grub)."
        confirmar_forte "Reverter os parâmetros?" || { info "Cancelado."; return 1; }
        fazer_backup
        local p esc
        for p in $GCN_PARAMS; do
            esc=$(printf '%s' "$p" | sed 's/\./\\./g')
            sudo sed -i "s/[[:space:]]*${esc}//g" /etc/default/grub
        done
        sudo update-grub && { ok "Parâmetros removidos."; REBOOT_NEEDED=1; }
        return 0
    fi

    riscos \
      "Edita /etc/default/grub e regenera o GRUB (update-grub)." \
      "Suporte do 'amdgpu' a GPUs GCN 1.x é considerado experimental: pode haver travamentos ou artefatos." \
      "Se algo falhar, pode ocorrer TELA PRETA no boot." \
      "Rollback imediato: no menu do GRUB, pressione 'e', apague os parâmetros 'amdgpu.*/radeon.*' da linha 'linux' e dê Ctrl+X." \
      "Rollback permanente: rodar esta opção novamente (reverte) ou restaurar $BACKUP_DIR/grub." \
      "Parâmetros a adicionar: $GCN_PARAMS"
    confirmar_forte "Aplicar os parâmetros?" || { info "Cancelado."; return 1; }

    fazer_backup
    sudo sed -i -E "s/^(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*)\"/\1 ${GCN_PARAMS}\"/" /etc/default/grub
    if ! grep -q 'amdgpu.si_support=1' /etc/default/grub; then
        erro "Não foi possível editar GRUB_CMDLINE_LINUX_DEFAULT. Restaurando o original."
        sudo cp -a "$BACKUP_DIR/grub" /etc/default/grub
        return 1
    fi
    if sudo update-grub; then
        ok "Parâmetros aplicados."
        REBOOT_NEEDED=1
    else
        erro "update-grub falhou. Restaurando o original."
        sudo cp -a "$BACKUP_DIR/grub" /etc/default/grub
        return 1
    fi
}

# ---------------------------- 5. Kernel HWE ----------------------------------
instalar_hwe() {
    titulo "KERNEL MAIS NOVO (HWE)"
    local ver pkg
    ver=$(. /etc/os-release && echo "$VERSION_ID")
    pkg="linux-generic-hwe-$ver"

    if ! apt-cache show "$pkg" >/dev/null 2>&1; then
        erro "O pacote '$pkg' não existe. Versões não-LTS já trazem kernel recente."
        return 1
    fi
    if dpkg -s "$pkg" >/dev/null 2>&1; then
        ok "O kernel HWE já está instalado."
        return 0
    fi

    riscos \
      "Download de centenas de MB e instalação de um novo kernel." \
      "Módulos DKMS de terceiros (VirtualBox, NVIDIA etc.) serão recompilados e podem falhar." \
      "Com Secure Boot ativo, módulos DKMS podem exigir novo registro de chave MOK." \
      "É necessário reiniciar; o kernel anterior continua disponível em 'Opções avançadas' do GRUB como alternativa." \
      "Rollback: iniciar pelo kernel antigo e remover o pacote '$pkg'."
    confirmar_forte "Instalar '$pkg'?" || { info "Cancelado."; return 1; }

    fazer_backup
    sudo apt-get update && sudo apt-get install -y "$pkg" && { ok "Kernel HWE instalado."; REBOOT_NEEDED=1; }
}

# ---------------------------- 6. Remover bloqueios ---------------------------
corrigir_bloqueios() {
    titulo "REMOVER BLOQUEIOS AO DRIVER AMDGPU"
    local grub_arqs bl_arqs
    grub_arqs=$(grep -lsw nomodeset /etc/default/grub /etc/default/grub.d/*.cfg 2>/dev/null)
    bl_arqs=$(grep -rEls '^[[:space:]]*(blacklist|install)[[:space:]]+amdgpu([[:space:]]|$)' /etc/modprobe.d 2>/dev/null)

    if [[ -z "$grub_arqs" && -z "$bl_arqs" ]]; then
        ok "Nenhum 'nomodeset' ou blacklist do amdgpu encontrado nos arquivos de configuração."
        if grep -qw nomodeset /proc/cmdline; then
            aviso "'nomodeset' está ativo neste boot, mas não vem destes arquivos (talvez edição manual no menu do GRUB)."
            aviso "Reiniciar normalmente deve resolver."
        fi
        return 0
    fi

    [[ -n "$grub_arqs" ]] && { info "'nomodeset' encontrado em:"; sed 's/^/  /' <<<"$grub_arqs"; }
    [[ -n "$bl_arqs" ]]   && { info "Blacklist do amdgpu encontrado em:"; sed 's/^/  /' <<<"$bl_arqs"; }

    riscos \
      "'nomodeset' costuma ser adicionado de propósito para contornar tela preta; removê-lo pode trazer o problema de volta." \
      "As linhas de blacklist serão comentadas (não apagadas), mas quem as colocou pode ter tido um motivo (ex.: passthrough para VM)." \
      "O GRUB e/ou o initramfs serão regenerados; falha nessa etapa pode atrapalhar o boot." \
      "Rollback: restaurar os arquivos de $BACKUP_DIR, rodar 'sudo update-grub' e 'sudo update-initramfs -u'."
    confirmar_forte "Remover os bloqueios?" || { info "Cancelado."; return 1; }

    fazer_backup
    local f
    if [[ -n "$grub_arqs" ]]; then
        while read -r f; do
            sudo sed -i -E '/^GRUB_CMDLINE_LINUX/ s/[[:space:]]*\bnomodeset\b//g' "$f"
        done <<<"$grub_arqs"
        sudo update-grub && ok "'nomodeset' removido e GRUB atualizado." && REBOOT_NEEDED=1
    fi
    if [[ -n "$bl_arqs" ]]; then
        while read -r f; do
            sudo sed -i -E 's/^([[:space:]]*(blacklist|install)[[:space:]]+amdgpu([[:space:]].*|$))/# desativado pelo amd-setup: \1/' "$f"
        done <<<"$bl_arqs"
        sudo update-initramfs -u && ok "Blacklist comentado e initramfs atualizado." && REBOOT_NEEDED=1
    fi
}

# ---------------------------- 7. PPA kisak-mesa ------------------------------
gerenciar_ppa() {
    titulo "MESA MAIS RECENTE (PPA kisak-mesa)"

    if grep -rqs 'kisak' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
        info "O PPA já está configurado. Esta opção irá REMOVÊ-LO e voltar ao Mesa oficial."
        riscos \
          "O ppa-purge fará DOWNGRADE dos pacotes de gráficos para a versão oficial do Ubuntu." \
          "Leia com atenção a lista de pacotes que o apt mostrar antes de confirmar." \
          "Interromper no meio pode deixar bibliotecas gráficas inconsistentes."
        confirmar_forte "Remover o PPA e reverter o Mesa?" || { info "Cancelado."; return 1; }
        fazer_backup
        sudo apt-get update -qq && sudo apt-get install -y ppa-purge || return 1
        sudo ppa-purge "$PPA" && { ok "PPA removido; Mesa oficial restaurado."; REBOOT_NEEDED=1; }
        return 0
    fi

    info "Dá acesso a versões mais novas do Mesa (melhor suporte a GPUs recentes e jogos)."
    riscos \
      "É um PPA de TERCEIROS: não é mantido pela Canonical nem pela AMD." \
      "Pode introduzir regressões (travamentos, tela preta, artefatos) que o Mesa oficial não tem." \
      "Atualiza bibliotecas centrais do sistema gráfico; pacotes 32 bits (Steam/Wine) precisam ser atualizados juntos." \
      "O PPA pode não oferecer pacotes para a sua versão do Ubuntu." \
      "Rollback: executar esta opção novamente (usa o ppa-purge)."
    confirmar_forte "Adicionar o PPA e atualizar o Mesa?" || { info "Cancelado."; return 1; }

    instalar_se_faltar add-apt-repository software-properties-common || return 1
    fazer_backup
    sudo add-apt-repository -y "$PPA" || { erro "Falha ao adicionar o PPA."; return 1; }
    sudo apt-get update || { erro "Falha no apt update."; return 1; }
    info "Revise a lista de pacotes que o apt vai atualizar antes de aceitar:"
    sudo apt-get upgrade && { ok "Mesa atualizado."; REBOOT_NEEDED=1; }
}

# ---------------------------- 8. ROCm ----------------------------------------
instalar_rocm() {
    titulo "ROCm (COMPUTAÇÃO / IA)"
    info "Só é necessário para computação na GPU (PyTorch com ROCm, HIP, etc.)."
    info "NÃO é necessário para jogos, vídeo ou uso normal do desktop."
    aviso "O suporte oficial cobre uma lista restrita de GPUs e versões do Ubuntu."
    aviso "Consulte a matriz de compatibilidade em rocm.docs.amd.com antes de continuar."
    info "O script não baixa o instalador sozinho, porque endereço e versão mudam a cada release."
    info "Baixe o .deb do 'amdgpu-install' seguindo o guia oficial de instalação do ROCm."

    local deb
    read -r -p "Caminho completo do .deb do amdgpu-install (ENTER para cancelar): " deb
    [[ -z "$deb" ]] && return 0
    deb="${deb/#\~/$HOME}"
    if [[ ! -f "$deb" || "$deb" != *.deb ]]; then
        erro "Arquivo inválido: $deb"
        return 1
    fi
    deb=$(realpath "$deb")

    riscos \
      "Download de vários GB e instalação de muitos pacotes." \
      "Adiciona repositórios da AMD ao apt, que passam a influenciar futuras atualizações." \
      "Com DKMS, um módulo de kernel da AMD substitui o do kernel; com Secure Boot, exige registro de chave MOK." \
      "Pode entrar em conflito com versões do Mesa de outras origens (ex.: PPA)." \
      "Você será adicionado aos grupos 'render' e 'video'; é preciso novo login para valer." \
      "Rollback: 'sudo amdgpu-install --uninstall' e remover o pacote amdgpu-install."

    local dkms_flag=""
    if confirmar "Usar o driver amdgpu do próprio kernel (--no-dkms, mais seguro)?"; then
        dkms_flag="--no-dkms"
    fi

    confirmar_forte "Instalar o ROCm?" || { info "Cancelado."; return 1; }
    fazer_backup
    sudo apt-get install "$deb" || { erro "Falha ao instalar o pacote amdgpu-install."; return 1; }
    sudo apt-get update
    # shellcheck disable=SC2086
    sudo amdgpu-install --usecase=rocm $dkms_flag || { erro "Falha na instalação do ROCm. Log: $LOG"; return 1; }
    sudo usermod -aG render,video "$USER"
    ok "ROCm instalado. Faça logout/login e teste com 'rocminfo'."
    REBOOT_NEEDED=1
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
        echo -e "\n${NEG}========== ATIVAÇÃO DE GPU AMD ==========${RESET}"
        echo " 1) Diagnóstico completo (somente leitura)"
        echo " 2) Instalar utilitários de diagnóstico (mesa-utils, vulkan-tools...)"
        echo " 3) Instalar/reparar Mesa e firmware"
        echo " 4) Ativar/reverter 'amdgpu' em GPUs antigas (GCN 1.0/1.1)"
        echo " 5) Instalar kernel mais novo (HWE) para GPUs recentes"
        echo " 6) Remover bloqueios (nomodeset / blacklist do amdgpu)"
        echo " 7) Adicionar/remover PPA kisak-mesa (Mesa mais recente)"
        echo " 8) Instalar ROCm (computação/IA)"
        echo " 0) Sair"
        read -r -p "Escolha: " op
        case "$op" in
            1) diagnostico; pausa ;;
            2) instalar_utilitarios; pausa ;;
            3) instalar_mesa; pausa ;;
            4) gcn_antigo; pausa ;;
            5) instalar_hwe; pausa ;;
            6) corrigir_bloqueios; pausa ;;
            7) gerenciar_ppa; pausa ;;
            8) instalar_rocm; pausa ;;
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