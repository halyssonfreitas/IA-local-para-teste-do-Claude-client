#!/usr/bin/env bash
# =============================================================================
# intel-setup.sh - Diagnóstico e ativação de GPU Intel (integrada ou Arc) no Ubuntu
# Uso: chmod +x intel-setup.sh && ./intel-setup.sh
# (execute como usuário normal; o script chama sudo quando necessário)
# =============================================================================

set -u

TS="$(date +%Y%m%d-%H%M%S)"
LOG="$HOME/intel-setup-$TS.log"
BACKUP_DIR="$HOME/intel-backup-$TS"
REBOOT_NEEDED=0

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
    sudo cp -a /etc/X11 "$BACKUP_DIR/" 2>/dev/null
    sudo cp -a /etc/apt/sources.list "$BACKUP_DIR/" 2>/dev/null
    sudo cp -a /etc/apt/sources.list.d "$BACKUP_DIR/" 2>/dev/null
    sudo chown -R "$USER": "$BACKUP_DIR" 2>/dev/null
    ok "Backup concluído."
}

# ---------------------------- Estado global ----------------------------------
TEM_INTEL=0; DRIVER_EM_USO=""; LLVMPIPE=0; GL_TESTADO=0; BLOQ_CMDLINE=0
BLACKLIST_ARQS=""; DISCRETA=0; GPU_IDS=""; KVER=0; DDX_INSTALADO=0

detectar_ids() {
    GPU_IDS=$(lspci -nn -d 8086: 2>/dev/null \
        | grep -Ei 'vga|3d controller|display controller' \
        | grep -oE '|$$8086:[0-9a-fA-F]{4}$$|' \
        | sed -E 's/|$$8086:([0-9a-fA-F]{4})$$|/\1/' \
        | tr 'A-F' 'a-f')
}

# ---------------------------- 1. Diagnóstico ---------------------------------
diagnostico() {
    titulo "DIAGNÓSTICO DA GPU INTEL"
    TEM_INTEL=0; DRIVER_EM_USO=""; LLVMPIPE=0; GL_TESTADO=0; BLOQ_CMDLINE=0
    BLACKLIST_ARQS=""; DISCRETA=0; GPU_IDS=""; KVER=0; DDX_INSTALADO=0

    info "Sistema: $(. /etc/os-release && echo "$PRETTY_NAME") | Kernel: $(uname -r)"
    info "Sessão gráfica: ${XDG_SESSION_TYPE:-desconhecida}"

    local kmaj kmin
    kmaj=$(uname -r | cut -d. -f1)
    kmin=$(uname -r | cut -d. -f2 | tr -cd '0-9')
    KVER=$(( ${kmaj:-0} * 100 + ${kmin:-0} ))

    titulo "Hardware de vídeo detectado"
    lspci -nnk | grep -EiA3 'vga|3d controller|display controller' || aviso "Nenhum controlador de vídeo listado."

    if lspci -nn | grep -Ei 'vga|3d controller|display controller' | grep -q '|$$8086:'; then
        TEM_INTEL=1
        ok "GPU Intel encontrada no barramento PCI."
        detectar_ids
        info "ID(s) de dispositivo Intel: $(echo "$GPU_IDS" | tr '\n' ' ')"
    else
        erro "Nenhuma GPU Intel detectada pelo lspci."
        aviso "Possíveis causas: GPU desativada na BIOS/UEFI, falha de hardware, ou VM sem passthrough."
        return 1
    fi

    if lspci -nn -d 8086: | grep -Ei 'vga|3d controller|display controller' \
        | grep -Eiq '\b(arc|dg1|dg2|battlemage|alchemist)\b|flex|data center gpu'; then
        DISCRETA=1
        info "GPU dedicada Intel (Arc/similar) detectada."
    else
        info "GPU integrada Intel (provavelmente)."
    fi

    local qtd
    qtd=$(lspci | grep -Eic 'vga|3d controller|display controller')
    if (( qtd > 1 )); then
        info "Mais de uma GPU detectada (gráficos híbridos)."
        info "Para rodar um programa na outra GPU, use: DRI_PRIME=1 nome-do-programa"
    fi

    titulo "Driver em uso"
    local drivers
    drivers=$(lspci -nnk -d 8086: | awk '/^[0-9a-fA-F]/ {gpu = ($0 ~ /VGA|3D controller|Display controller/)} gpu && /Kernel driver in use/ {print $5}')
    if grep -qx i915 <<<"$drivers"; then
        DRIVER_EM_USO="i915"
        ok "Driver 'i915' (padrão da Intel no kernel) em uso."
    elif grep -qx xe <<<"$drivers"; then
        DRIVER_EM_USO="xe"
        ok "Driver 'xe' (novo driver da Intel para GPUs recentes) em uso."
    else
        aviso "Nenhum driver de kernel ativo para a GPU Intel."
    fi
    lsmod | grep -E '^(i915|xe) ' || info "Nem 'i915' nem 'xe' estão carregados."

    titulo "Versão do kernel"
    info "Kernel atual: $(uname -r)"
    if (( DISCRETA && KVER < 602 )); then
        aviso "Placas Arc exigem kernel 6.2 ou superior; o seu é mais antigo (opção 4)."
    fi
    info "GPUs muito recentes (Battlemage, Lunar Lake, Arrow Lake) costumam exigir kernels novos (6.12+ é o mais seguro)."

    titulo "Dispositivos DRM"
    ls -l /dev/dri/ 2>/dev/null | sed 's/^/  /' || aviso "/dev/dri não existe (sem driver gráfico ativo)."

    titulo "Bloqueios conhecidos"
    if grep -Eq '(^|[[:space:]])(nomodeset|i915\.modeset=0|xe\.modeset=0)([[:space:]]|$)' /proc/cmdline; then
        BLOQ_CMDLINE=1
        aviso "'nomodeset' ou 'modeset=0' ativo neste boot: isso DESLIGA o driver de vídeo."
    else
        ok "Nenhum 'nomodeset'/'modeset=0' ativo."
    fi
    if grep -Eq 'module_blacklist=[^[:space:]]*(i915|xe)' /proc/cmdline; then
        BLOQ_CMDLINE=1
        aviso "'module_blacklist' na linha de boot bloqueia i915/xe (remova manualmente do GRUB)."
    fi
    BLACKLIST_ARQS=$(grep -rEls '^[[:space:]]*(blacklist|install)[[:space:]]+(i915|xe)([[:space:]]|$)' /etc/modprobe.d /usr/lib/modprobe.d 2>/dev/null)
    if [[ -n "$BLACKLIST_ARQS" ]]; then
        aviso "Os módulos 'i915'/'xe' estão bloqueados em:"
        sed 's/^/  /' <<<"$BLACKLIST_ARQS"
    else
        ok "Nenhum blacklist de i915/xe em /etc/modprobe.d."
    fi

    titulo "Firmware (GuC/HuC/DMC)"
    if compgen -G "/lib/firmware/i915/*" >/dev/null || compgen -G "/usr/lib/firmware/i915/*" >/dev/null \
       || compgen -G "/lib/firmware/xe/*" >/dev/null || compgen -G "/usr/lib/firmware/xe/*" >/dev/null; then
        ok "Arquivos de firmware da Intel presentes."
    else
        aviso "Firmware da Intel ausente (pacote linux-firmware)."
    fi
    sudo dmesg 2>/dev/null | grep -iE 'guc|huc' | grep -iE 'i915|\bxe\b' | tail -n 4 | sed 's/^/  /'

    if (( DISCRETA )); then
        titulo "Resizable BAR (importante para Arc)"
        local slot
        while read -r slot _; do
            info "Dispositivo $slot:"
            sudo lspci -vv -s "$slot" </dev/null 2>/dev/null \
                | grep -Ei 'Resizable BAR|Region [0-9]+: Memory.*prefetchable' | sed 's/^[[:space:]]*/  /'
        done < <(lspci -nn -d 8086: | grep -Ei 'vga|3d controller|display controller')
        info "Se a região prefetchable for de apenas 256M, o Resizable BAR provavelmente está desligado."
        info "Ative 'Above 4G Decoding' e 'Resizable BAR' na BIOS/UEFI (este script não altera a BIOS)."
    fi

    titulo "Driver Xorg legado"
    if dpkg -s xserver-xorg-video-intel >/dev/null 2>&1; then
        DDX_INSTALADO=1
        aviso "'xserver-xorg-video-intel' instalado: o driver 'modesetting' do Xorg é o recomendado (opção 9)."
    else
        ok "Sem driver Xorg legado da Intel (o 'modesetting' padrão está em uso)."
    fi

    titulo "Secure Boot (informativo)"
    if tem_cmd mokutil; then
        mokutil --sb-state 2>&1 | head -n 1
        info "Os drivers i915/xe do kernel já são assinados: normalmente NÃO exigem registro de chave."
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
            aviso "Você não está no grupo '$g' (desktop comum funciona sem; computação/OpenCL exige)."
        fi
    done

    titulo "Computação (OpenCL / Level Zero)"
    if tem_cmd clinfo; then
        clinfo -l 2>/dev/null | sed 's/^/  /' || info "Nenhuma plataforma OpenCL encontrada."
    else
        info "clinfo ausente; OpenCL é necessário só para computação, não para desktop ou jogos (opção 8)."
    fi

    titulo "Mensagens relevantes do kernel"
    sudo dmesg 2>/dev/null | grep -iE 'i915|\bxe\b' \
        | grep -iE 'fail|error|firmware|timeout|reset|hang' | tail -n 8 \
        || true

    titulo "RESUMO"
    if [[ -z "$DRIVER_EM_USO" ]]; then
        aviso "GPU Intel detectada, mas SEM driver carregado."
        (( BLOQ_CMDLINE )) && info "-> Bloqueio na linha de boot: use a opção 5."
        [[ -n "$BLACKLIST_ARQS" ]] && info "-> i915/xe em blacklist: use a opção 5."
        info "-> Verifique o firmware e o Mesa (opção 3)."
        info "-> Se a GPU for muito recente, tente um kernel mais novo (opção 4) e, se preciso, force_probe (opção 6)."
    elif (( LLVMPIPE )); then
        aviso "Driver '$DRIVER_EM_USO' carregado, mas o OpenGL roda por SOFTWARE (llvmpipe)."
        info "-> Reinstale o Mesa e o firmware (opção 3) e reinicie a sessão."
    elif (( DDX_INSTALADO )); then
        aviso "Driver funcionando, mas há o driver Xorg legado instalado (pode causar tearing/instabilidade)."
        info "-> Considere a opção 9."
    elif (( ! GL_TESTADO )); then
        ok "Driver '$DRIVER_EM_USO' carregado. Instale os utilitários (opção 2) para validar a aceleração 3D."
    else
        ok "Sua GPU Intel está ATIVA e acelerando normalmente. Nada a fazer."
    fi
    log "Diagnóstico concluído. DRIVER=$DRIVER_EM_USO LLVMPIPE=$LLVMPIPE BLOQ_CMDLINE=$BLOQ_CMDLINE DISCRETA=$DISCRETA"
}

# ---------------------------- 2. Utilitários ---------------------------------
instalar_utilitarios() {
    titulo "INSTALAR UTILITÁRIOS DE DIAGNÓSTICO"
    local pkgs=(mesa-utils vulkan-tools vainfo intel-gpu-tools)
    riscos \
      "Pacotes pequenos, do repositório oficial do Ubuntu." \
      "Nenhuma configuração do sistema é alterada." \
      "O 'intel_gpu_top' (do intel-gpu-tools) normalmente precisa de sudo para monitorar a GPU." \
      "Rollback: sudo apt remove ${pkgs[*]}"
    confirmar "Instalar ${pkgs[*]}?" || { info "Cancelado."; return 1; }
    sudo apt-get update -qq && sudo apt-get install -y "${pkgs[@]}" && ok "Utilitários instalados."
}

# ---------------------------- 3. Mesa + firmware + vídeo ---------------------
instalar_mesa() {
    titulo "INSTALAR / REPARAR MESA, FIRMWARE E ACELERAÇÃO DE VÍDEO"
    riscos \
      "Atualiza pacotes de gráficos usados pela interface inteira (Mesa, firmware, VA-API)." \
      "Falha no meio do processo pode deixar o apt/dpkg quebrado e a interface instável." \
      "Pode ser necessário reiniciar a sessão ou o computador depois." \
      "Rollback: reinstalar as versões oficiais do Ubuntu (apt install --reinstall)."
    confirmar_forte "Continuar?" || { info "Cancelado."; return 1; }

    local va_pkg="intel-media-va-driver"
    if confirmar "Sua GPU é anterior à 5ª geração Core (Broadwell, ex.: HD 4000)? Se sim, usa i965-va-driver"; then
        va_pkg="i965-va-driver"
    fi

    local flag=""
    confirmar "Forçar reinstalação dos pacotes (útil se houver arquivos corrompidos)?" && flag="--reinstall"

    fazer_backup
    sudo apt-get update || { erro "Falha no apt update."; return 1; }

    local pkgs=() p
    for p in linux-firmware libgl1-mesa-dri libglx-mesa0 libegl-mesa0 libgbm1 \
             mesa-vulkan-drivers "$va_pkg"; do
        if apt-cache show "$p" >/dev/null 2>&1; then
            pkgs+=("$p")
        else
            aviso "Pacote indisponível nesta versão do Ubuntu, ignorado: $p"
        fi
    done
    # shellcheck disable=SC2086
    sudo apt-get install -y $flag "${pkgs[@]}" || { erro "Falha na instalação. Log: $LOG"; return 1; }
    ok "Mesa, firmware e driver de vídeo atualizados."
    REBOOT_NEEDED=1
}

# ---------------------------- 4. Kernel HWE ----------------------------------
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

# ---------------------------- 5. Remover bloqueios ---------------------------
corrigir_bloqueios() {
    titulo "REMOVER BLOQUEIOS AOS DRIVERS i915/xe"
    local grub_arqs bl_arqs
    grub_arqs=$(grep -lsE '^GRUB_CMDLINE_LINUX.*(nomodeset|i915\.modeset=0)' /etc/default/grub /etc/default/grub.d/*.cfg 2>/dev/null)
    bl_arqs=$(grep -rEls '^[[:space:]]*(blacklist|install)[[:space:]]+(i915|xe)([[:space:]]|$)' /etc/modprobe.d 2>/dev/null)

    if [[ -z "$grub_arqs" && -z "$bl_arqs" ]]; then
        ok "Nenhum 'nomodeset', 'i915.modeset=0' ou blacklist encontrado nos arquivos de configuração."
        if grep -Eq '(^|[[:space:]])(nomodeset|i915\.modeset=0)([[:space:]]|$)' /proc/cmdline; then
            aviso "O bloqueio está ativo neste boot, mas não vem destes arquivos (talvez edição manual no menu do GRUB)."
            aviso "Reiniciar normalmente deve resolver."
        fi
        return 0
    fi

    [[ -n "$grub_arqs" ]] && { info "Parâmetros de bloqueio encontrados em:"; sed 's/^/  /' <<<"$grub_arqs"; }
    [[ -n "$bl_arqs" ]]   && { info "Blacklist de i915/xe encontrado em:"; sed 's/^/  /' <<<"$bl_arqs"; }

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
            sudo sed -i -E '/^GRUB_CMDLINE_LINUX/ { s/[[:space:]]*\bnomodeset\b//g; s/[[:space:]]*i915\.modeset=0//g }' "$f"
        done <<<"$grub_arqs"
        sudo update-grub && ok "Parâmetros removidos e GRUB atualizado." && REBOOT_NEEDED=1
    fi
    if [[ -n "$bl_arqs" ]]; then
        while read -r f; do
            sudo sed -i -E 's/^([[:space:]]*(blacklist|install)[[:space:]]+(i915|xe)([[:space:]].*|$))/# desativado pelo intel-setup: \1/' "$f"
        done <<<"$bl_arqs"
        sudo update-initramfs -u && ok "Blacklist comentado e initramfs atualizado." && REBOOT_NEEDED=1
    fi
}

# ---------------------------- 6. force_probe (GPUs muito recentes) -----------
force_probe() {
    titulo "FORCE_PROBE (GPUs MUITO RECENTES)"
    info "Alguns kernels ainda não ativam por padrão GPUs lançadas recentemente."
    info "O parâmetro force_probe obriga o driver a assumir o controle da placa."

    if grep -qE '^GRUB_CMDLINE_LINUX_DEFAULT=.*(i915|xe)\.force_probe=' /etc/default/grub; then
        info "Já existem parâmetros force_probe no GRUB. Esta opção irá REMOVÊ-LOS."
        riscos \
          "O sistema volta ao comportamento padrão do kernel no próximo boot." \
          "Se a GPU só funcionava por causa do force_probe, ela deixará de ser ativada." \
          "O GRUB será regenerado (update-grub)."
        confirmar_forte "Reverter os parâmetros?" || { info "Cancelado."; return 1; }
        fazer_backup
        sudo sed -i -E '/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/[[:space:]]*(i915|xe)\.force_probe=[^[:space:]"]*//g' /etc/default/grub
        if sudo update-grub; then
            ok "Parâmetros removidos."
            REBOOT_NEEDED=1
        else
            erro "update-grub falhou. Restaurando o original."
            sudo cp -a "$BACKUP_DIR/grub" /etc/default/grub
            return 1
        fi
        return 0
    fi

    detectar_ids
    if [[ -z "$GPU_IDS" ]]; then
        erro "Nenhum ID de GPU Intel detectado."
        return 1
    fi
    info "ID(s) detectado(s): $(echo "$GPU_IDS" | tr '\n' ' ')"
    aviso "Use isto só se o kernel atual não ativou a GPU e a opção 4 (kernel mais novo) não resolveu."

    local id
    read -r -p "Digite o ID da GPU (4 caracteres hex) ou ENTER para cancelar: " id
    [[ -z "$id" ]] && return 0
    id="${id,,}"
    if [[ ! "$id" =~ ^[0-9a-f]{4}$ ]] || ! grep -qw "$id" <<<"$GPU_IDS"; then
        erro "ID inválido ou não corresponde a uma GPU Intel detectada: $id"
        return 1
    fi

    local params=""
    PS3="Driver a forçar: "
    echo "  1) i915 (driver tradicional)"
    echo "  2) xe (driver novo, desliga o i915 para este ID)"
    echo "  3) cancelar"
    local op
    while true; do
        read -r -p "Escolha [1-3]: " op
        case "$op" in
            1) params="i915.force_probe=$id"; break ;;
            2) params="i915.force_probe=!$id xe.force_probe=$id"; break ;;
            3) info "Cancelado."; return 0 ;;
            *) echo "Opção inválida." ;;
        esac
    done

    riscos \
      "Edita /etc/default/grub e regenera o GRUB (update-grub)." \
      "Suporte forçado é EXPERIMENTAL: pode haver travamentos, artefatos ou tela preta." \
      "Se a GPU não for compatível com o driver escolhido, o boot gráfico pode falhar." \
      "Rollback imediato: no menu do GRUB, pressione 'e', apague '*.force_probe=...' da linha 'linux' e dê Ctrl+X." \
      "Rollback permanente: rodar esta opção novamente (reverte) ou restaurar $BACKUP_DIR/grub." \
      "Parâmetros a adicionar: $params"
    confirmar_forte "Aplicar os parâmetros?" || { info "Cancelado."; return 1; }

    fazer_backup
    sudo sed -i -E "s/^(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*)\"/\1 ${params}\"/" /etc/default/grub
    if ! grep -q 'force_probe=' /etc/default/grub; then
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

    info "Dá acesso a versões mais novas do Mesa (melhor suporte a GPUs recentes, como as Arc, e a jogos)."
    riscos \
      "É um PPA de TERCEIROS: não é mantido pela Canonical nem pela Intel." \
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

# ---------------------------- 8. Computação (OpenCL / Level Zero) ------------
instalar_compute() {
    titulo "COMPUTAÇÃO NA GPU (OpenCL / Level Zero)"
    info "Só é necessário para computação na GPU (OpenCL, SYCL/oneAPI, etc.)."
    info "NÃO é necessário para jogos, vídeo ou uso normal do desktop."
    aviso "O suporte depende da geração da GPU (Gen12+ e Arc são os mais bem atendidos)."
    info "Este script instala só os runtimes dos repositórios do Ubuntu, não o oneAPI completo."

    sudo apt-get update -qq
    local pkgs=() p
    for p in intel-opencl-icd clinfo libze1; do
        apt-cache show "$p" >/dev/null 2>&1 && pkgs+=("$p")
    done
    for p in libze-intel-gpu1 intel-level-zero-gpu; do
        if apt-cache show "$p" >/dev/null 2>&1; then
            pkgs+=("$p")
            break
        fi
    done
    if (( ${#pkgs[@]} == 0 )); then
        erro "Nenhum pacote de computação da Intel encontrado nos repositórios."
        return 1
    fi

    riscos \
      "Pacotes a instalar: ${pkgs[*]}" \
      "As versões do repositório do Ubuntu podem ser mais antigas que as publicadas pela Intel." \
      "Você será adicionado aos grupos 'render' e 'video'; é preciso novo login para valer." \
      "GPUs mais antigas podem exigir o runtime legado (pacote diferente) e não funcionar com este." \
      "Rollback: sudo apt remove ${pkgs[*]}"
    confirmar_forte "Instalar os runtimes de computação?" || { info "Cancelado."; return 1; }

    fazer_backup
    sudo apt-get install -y "${pkgs[@]}" || { erro "Falha na instalação. Log: $LOG"; return 1; }
    sudo usermod -aG render,video "$USER"
    ok "Runtimes instalados. Faça logout/login e teste com 'clinfo -l'."
}

# ---------------------------- 9. Remover driver Xorg legado ------------------
remover_ddx() {
    titulo "REMOVER xserver-xorg-video-intel (DRIVER XORG LEGADO)"
    if ! dpkg -s xserver-xorg-video-intel >/dev/null 2>&1; then
        ok "O pacote não está instalado; nada a fazer."
        return 0
    fi

    info "O driver 'modesetting' do próprio Xorg é o recomendado para GPUs Intel atuais."
    local confs
    confs=$(grep -rlsiE 'Driver[[:space:]]+"intel"' /etc/X11 2>/dev/null)
    if [[ -n "$confs" ]]; then
        aviso "Arquivos de configuração que forçam o driver 'intel':"
        sed 's/^/  /' <<<"$confs"
    fi

    riscos \
      "O pacote será removido com purge; o Xorg passará a usar o 'modesetting'." \
      "Arquivos que forçam Driver \"intel\" (listados acima, se houver) serão RENOMEADOS, senão o Xorg falharia ao iniciar." \
      "Em GPUs muito antigas (anteriores à Gen4), o driver legado pode ser necessário." \
      "Em sessões Wayland o pacote não é usado, então o efeito prático é só no Xorg." \
      "Rollback: sudo apt install xserver-xorg-video-intel e restaurar os arquivos de $BACKUP_DIR/X11."
    confirmar_forte "Remover o driver Xorg legado?" || { info "Cancelado."; return 1; }

    fazer_backup
    local f
    if [[ -n "$confs" ]]; then
        while read -r f; do
            sudo mv "$f" "$f.disabled-$TS" && info "Renomeado: $f"
        done <<<"$confs"
    fi
    sudo apt-get remove --purge -y xserver-xorg-video-intel && { ok "Driver legado removido."; REBOOT_NEEDED=1; }
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
        echo -e "\n${NEG}========== ATIVAÇÃO DE GPU INTEL ==========${RESET}"
        echo " 1) Diagnóstico completo (somente leitura)"
        echo " 2) Instalar utilitários de diagnóstico (mesa-utils, vulkan-tools, intel-gpu-tools...)"
        echo " 3) Instalar/reparar Mesa, firmware e aceleração de vídeo"
        echo " 4) Instalar kernel mais novo (HWE) para GPUs recentes"
        echo " 5) Remover bloqueios (nomodeset / blacklist do i915/xe)"
        echo " 6) Ativar/reverter force_probe (GPUs muito recentes)"
        echo " 7) Adicionar/remover PPA kisak-mesa (Mesa mais recente)"
        echo " 8) Instalar runtimes de computação (OpenCL / Level Zero)"
        echo " 9) Remover driver Xorg legado (xserver-xorg-video-intel)"
        echo " 0) Sair"
        read -r -p "Escolha: " op
        case "$op" in
            1) diagnostico; pausa ;;
            2) instalar_utilitarios; pausa ;;
            3) instalar_mesa; pausa ;;
            4) instalar_hwe; pausa ;;
            5) corrigir_bloqueios; pausa ;;
            6) force_probe; pausa ;;
            7) gerenciar_ppa; pausa ;;
            8) instalar_compute; pausa ;;
            9) remover_ddx; pausa ;;
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