#!/usr/bin/env bash
# redimensionar-menu.sh
# Menu para diagnosticar e redimensionar / (aumentar) e /home (diminuir)
# Execução automática suportada somente com LVM + ext4 no /home.

set -u

[[ $EUID -eq 0 ]] || exec sudo bash "$0" "$@"

HOME_MNT="/home"
MARGEM_PCT=15          # folga mínima sobre o usado no /home (%)
MARGEM_MIN_MB=5120     # folga mínima absoluta (5 GiB)

die()    { echo "ERRO: $*" >&2; exit 1; }
info()   { echo "[*] $*"; }
warn()   { echo "[!] $*"; }
pausar() { echo; read -r -p "Pressione ENTER para voltar ao menu..." _; }
confirm(){ local r; read -r -p "$1 [s/N] " r; [[ "${r,,}" == s* || "${r,,}" == y* ]]; }

need_cmds() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null || die "Comando ausente: $c (instale: sudo apt install lvm2 e2fsprogs psmisc)"
  done
}

# Executa uma função em subshell com modo estrito, sem derrubar o menu
rodar() {
  (
    set -Eeuo pipefail
    trap 'echo; warn "Falha na linha $LINENO. Nada mais foi executado depois do erro."; warn "Verifique o estado com: lsblk -f ; lvs ; df -h"' ERR
    "$@"
  )
  local rc=$?
  (( rc == 0 )) || warn "A operação terminou com erro (código $rc)."
  pausar
}

# ---------------------------------------------------------------- utilitários

resolve_dev() {
  local src="${1%%|$$*}"
  case "$src" in
    UUID=*)  blkid -U "${src#UUID=}" ;;
    LABEL=*) blkid -L "${src#LABEL=}" ;;
    /dev/*)  readlink -f "$src" ;;
    *)       echo "" ;;
  esac
}

lv_of() {
  local d p
  d=$(readlink -f "$1")
  while read -r p; do
    if [[ "$(readlink -f "$p")" == "$d" ]]; then echo "$p"; return 0; fi
  done < <(lvs --noheadings -o lv_path 2>/dev/null | awk '{print $1}')
  return 0
}

lv_size_mb()  { lvs --noheadings --units m --nosuffix -o lv_size "$1" | awk '{printf "%d", $1}'; }
vg_free_mb()  { vgs --noheadings --units m --nosuffix -o vg_free "$1" | awk '{printf "%d", $1}'; }
vg_extent_mb(){ vgs --noheadings --units m --nosuffix -o vg_extent_size "$1" | awk '{printf "%d", $1}'; }
fs_type()     { blkid -s TYPE -o value "$1"; }

fs_used_mb() {
  local dev="$1" fs out bc fb bs
  fs=$(fs_type "$dev")
  if [[ "$fs" == ext* ]]; then
    out=$(dumpe2fs -h "$dev" 2>/dev/null || true)
    bc=$(awk -F: '/^Block count/{gsub(/ /,"",$2);print $2}' <<<"$out")
    fb=$(awk -F: '/^Free blocks/{gsub(/ /,"",$2);print $2}' <<<"$out")
    bs=$(awk -F: '/^Block size/{gsub(/ /,"",$2);print $2}' <<<"$out")
    if [[ -n "$bc" && -n "$fb" && -n "$bs" ]]; then
      echo $(( (bc - fb) * bs / 1024 / 1024 )); return 0
    fi
  fi
  if findmnt -rn "$HOME_MNT" >/dev/null 2>&1; then
    df -BM --output=used "$HOME_MNT" | tail -1 | tr -dc '0-9'; echo; return 0
  fi
  echo 0
}

# Detecta dispositivos. Retorna 1 se não for LVM.
detect() {
  ROOT_SRC=$(findmnt -no SOURCE /)
  ROOT_DEV=$(resolve_dev "$ROOT_SRC")

  if findmnt -rn "$HOME_MNT" >/dev/null 2>&1; then
    HOME_SRC=$(findmnt -no SOURCE "$HOME_MNT")
  else
    HOME_SRC=$(findmnt --fstab -no SOURCE "$HOME_MNT" 2>/dev/null | head -1 || true)
  fi
  [[ -n "${HOME_SRC:-}" ]] || die "/home não é um filesystem separado (sem entrada própria no fstab)."
  HOME_DEV=$(resolve_dev "$HOME_SRC")

  [[ -n "$ROOT_DEV" && -n "$HOME_DEV" ]] || die "Não consegui resolver os dispositivos de / e /home."
  [[ "$ROOT_DEV" != "$HOME_DEV" ]] || die "/ e /home estão no mesmo dispositivo."

  ROOT_LV=$(lv_of "$ROOT_DEV")
  HOME_LV=$(lv_of "$HOME_DEV")
  [[ -n "$ROOT_LV" && -n "$HOME_LV" ]] || return 1

  local rvg hvg
  rvg=$(lvs --noheadings -o vg_name "$ROOT_LV" | xargs)
  hvg=$(lvs --noheadings -o vg_name "$HOME_LV" | xargs)
  [[ "$rvg" == "$hvg" ]] || die "/ e /home estão em Volume Groups diferentes ($rvg / $hvg)."
  VG="$rvg"
  return 0
}

# Calcula limites (depois de detect)
calcular() {
  ROOT_FS=$(fs_type "$ROOT_DEV")
  HOME_FS=$(fs_type "$HOME_DEV")
  HOME_MB=$(lv_size_mb "$HOME_LV")
  HOME_USED=$(fs_used_mb "$HOME_DEV")
  VG_FREE=$(vg_free_mb "$VG")
  EXT_MB=$(vg_extent_mb "$VG")
  MARGEM=$(( HOME_USED * MARGEM_PCT / 100 ))
  if (( MARGEM < MARGEM_MIN_MB )); then MARGEM=$MARGEM_MIN_MB; fi
  MIN_HOME=$(( HOME_USED + MARGEM ))
  MAX_SHRINK=$(( HOME_MB - MIN_HOME ))
  if (( MAX_SHRINK < 0 )); then MAX_SHRINK=0; fi
}

# ---------------------------------------------------------------- opções

diagnostico() {
  info "=== Data e kernel ==="; date; uname -r
  info "=== Discos e partições ==="; lsblk -f
  info "=== Uso de disco ==="; df -hT -x tmpfs -x devtmpfs -x squashfs
  info "=== /etc/fstab ==="; grep -v '^\s*#' /etc/fstab | sed '/^\s*$/d'
  if command -v pvs >/dev/null; then
    info "=== LVM ==="; pvs 2>/dev/null || true; vgs 2>/dev/null || true; lvs 2>/dev/null || true
  fi
  info "=== Maiores diretórios em / (mesmo filesystem) ==="
  du -xh --max-depth=1 / 2>/dev/null | sort -h | tail -n 12 || true
  if command -v smartctl >/dev/null; then
    info "=== SMART (saúde do disco) ==="
    local d
    for d in $(lsblk -dno NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}'); do
      echo "$d: $(smartctl -H "$d" 2>/dev/null | grep -i 'overall' || echo 'sem informação')"
    done
  else
    warn "smartctl ausente (sudo apt install smartmontools) para checar a saúde do disco."
  fi
}

viabilidade() {
  info "=== Análise de viabilidade ==="
  if detect; then
    calcular
    echo "LVM detectado. VG: $VG (extensão: ${EXT_MB} MiB)"
    echo "Root LV : $ROOT_LV  ($(lv_size_mb "$ROOT_LV") MiB) fs=$ROOT_FS"
    echo "Home LV : $HOME_LV  (${HOME_MB} MiB) fs=$HOME_FS, usado ~${HOME_USED} MiB"
    echo "Espaço livre no VG (sem mexer em nada)  : ${VG_FREE} MiB (~$(( VG_FREE / 1024 )) GiB)"
    echo "Máximo que o /home pode ceder com folga : ${MAX_SHRINK} MiB (~$(( MAX_SHRINK / 1024 )) GiB)"
    echo "Total possível para adicionar ao /      : ~$(( (VG_FREE + MAX_SHRINK) / 1024 )) GiB"
    [[ "$HOME_FS" == "ext4" ]] || warn "/home não é ext4: a redução NÃO é suportada por este script."
    findmnt -rn "$HOME_MNT" >/dev/null 2>&1 && warn "/home está montado: para reduzir, use Recovery Mode ou Live USB."
  else
    warn "/ e /home não estão em LVM (partições comuns ou outro layout)."
    cat <<'EOF'
Recomendação: use um pendrive Live com GParted. O espaço só pode ser transferido
entre partições ADJACENTES; se o /home vem depois do /, será preciso movê-lo
(operação demorada e arriscada). Faça backup completo e mantenha na tomada.
Alternativa sem risco: use a opção de limpeza segura deste menu.
EOF
  fi
}

usando_home() {
  info "Processos usando $HOME_MNT:"
  fuser -vm "$HOME_MNT" 2>&1 | head -n 30 || true
  echo
  info "Usuários logados:"; who || true
}

limpeza() {
  info "Uso atual do /:"; df -h /
  echo
  if confirm "Limpar cache de pacotes (apt-get clean)?"; then apt-get clean; fi
  echo
  info "Simulação do autoremove (pacotes que seriam removidos):"
  apt-get -s autoremove 2>/dev/null | grep '^Remv' || echo "Nada a remover."
  if confirm "Executar apt-get autoremove?"; then apt-get -y autoremove; fi
  echo
  if confirm "Reduzir logs do journal para 200 MB?"; then journalctl --vacuum-size=200M; fi
  echo
  if command -v snap >/dev/null; then
    info "Revisões antigas de snaps:"
    snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}' || true
    if confirm "Remover revisões antigas de snaps?"; then
      snap list --all | awk '/disabled/{print $1, $3}' | while read -r n r; do
        snap remove "$n" --revision="$r" || true
      done
    fi
  fi
  echo
  info "Uso do / depois:"; df -h /
}

salvar_metadados() {
  BACKUP_DIR="/root/resize-backup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BACKUP_DIR"
  info "Salvando estado atual em $BACKUP_DIR"
  cp -a /etc/fstab "$BACKUP_DIR/fstab"
  lsblk -f > "$BACKUP_DIR/lsblk.txt"
  blkid > "$BACKUP_DIR/blkid.txt"
  local d
  for d in $(lsblk -dno NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}'); do
    sfdisk -d "$d" > "$BACKUP_DIR/ptable-$(basename "$d").txt" 2>/dev/null || true
  done
  if command -v lvs >/dev/null && lvs >/dev/null 2>&1; then
    lvs -a -o+devices > "$BACKUP_DIR/lvs.txt"
    local vg
    for vg in $(vgs --noheadings -o vg_name | xargs); do
      vgcfgbackup -f "$BACKUP_DIR/vg-%s.vg" "$vg" >/dev/null
    done
  fi
  sync
  info "Backup de metadados salvo em $BACKUP_DIR"
  warn "Isto NÃO substitui o backup dos seus arquivos em outro disco."
}

executar() {
  need_cmds lvs vgs lvextend lvreduce e2fsck resize2fs dumpe2fs fuser blkid findmnt vgcfgbackup

  detect || die "Execução automática só com LVM. Use a opção 2 e o GParted Live."
  if findmnt -no OPTIONS / | tr ',' '\n' | grep -qx ro; then
    die "/ está somente leitura. Rode antes: mount -o remount,rw /"
  fi
  calcular

  [[ "$ROOT_FS" == "ext4" || "$ROOT_FS" == "xfs" ]] || die "Filesystem do / ($ROOT_FS) não suportado."

  echo "VG: $VG | livre: ${VG_FREE} MiB | /home pode ceder até ${MAX_SHRINK} MiB (~$(( MAX_SHRINK / 1024 )) GiB)"
  local gb
  read -r -p "Quantos GiB deseja ADICIONAR ao /? " gb
  [[ "$gb" =~ ^[1-9][0-9]*$ ]] || die "Informe um número inteiro de GiB."

  local add_mb=$(( gb * 1024 ))
  local falta=$(( add_mb - VG_FREE ))
  if (( falta < 0 )); then falta=0; fi
  if (( falta > 0 )); then falta=$(( (falta + EXT_MB - 1) / EXT_MB * EXT_MB )); fi
  local new_home=$(( HOME_MB - falta ))

  if (( falta > 0 )); then
    [[ "$HOME_FS" == "ext4" ]] || die "Redução do /home só é suportada em ext4 (atual: $HOME_FS)."
    (( HOME_USED > 0 )) || die "Não consegui medir o uso do /home. Abortando por segurança."
    (( new_home >= MIN_HOME )) || die "O /home ficaria com ${new_home} MiB, abaixo do mínimo seguro de ${MIN_HOME} MiB. Peça um valor menor."
  fi

  echo
  echo "================ PLANO ================"
  echo "Adicionar ao /        : ${add_mb} MiB (${gb} GiB)"
  echo "Usar do espaço livre  : $(( add_mb - falta > VG_FREE ? VG_FREE : add_mb - falta )) MiB"
  echo "Retirar do /home      : ${falta} MiB"
  echo "Novo tamanho do /home : ${new_home} MiB (mínimo seguro: ${MIN_HOME} MiB)"
  echo "======================================="
  echo

  local r
  read -r -p "Você tem BACKUP dos dados importantes em outro disco? Digite 'TENHO BACKUP': " r
  [[ "$r" == "TENHO BACKUP" ]] || die "Cancelado."
  read -r -p "Confirmar execução? Digite 'SIM': " r
  [[ "$r" == "SIM" ]] || die "Cancelado."

  salvar_metadados

  if (( falta > 0 )); then
    if findmnt -rn "$HOME_MNT" >/dev/null 2>&1; then
      info "Desmontando $HOME_MNT ..."
      if ! umount "$HOME_MNT"; then
        fuser -vm "$HOME_MNT" || true
        die "Não foi possível desmontar o /home (em uso). Use Recovery Mode ou Live USB. Nada foi alterado."
      fi
    fi
    info "Verificando o filesystem do /home (e2fsck)..."
    e2fsck -f -p "$HOME_DEV" || die "e2fsck encontrou problemas. Nada foi alterado. Corrija com 'e2fsck -f' antes de continuar."

    info "Reduzindo /home para ${new_home} MiB (filesystem e LV na ordem correta)..."
    lvreduce --yes --resizefs -L "${new_home}m" "$HOME_LV"

    info "Verificando /home após a redução..."
    e2fsck -f -p "$HOME_DEV" || die "e2fsck pós-redução reportou problemas. NÃO continue; procure ajuda."
    info "Remontando /home..."
    mount "$HOME_MNT" || warn "Não remontou automaticamente; rode 'mount -a'."
  fi

  local livre; livre=$(vg_free_mb "$VG")
  (( livre > 0 )) || die "Sem espaço livre no VG para estender o /."

  info "Aumentando o / (filesystem junto)..."
  if (( livre <= add_mb )); then
    lvextend --resizefs -l +100%FREE "$ROOT_LV"
  else
    lvextend --resizefs -L "+${add_mb}m" "$ROOT_LV"
  fi

  echo
  info "Concluído. Estado final:"
  df -hT / "$HOME_MNT" || true
  lvs
}

estado_atual() {
  lsblk -f; echo; df -hT -x tmpfs -x devtmpfs -x squashfs; echo
  lvs 2>/dev/null || true
}

# ---------------------------------------------------------------- menu

while true; do
  clear
  echo "=============================================="
  echo "   Redimensionar / e /home (Ubuntu, LVM)"
  echo "=============================================="
  echo " 1) Diagnóstico completo"
  echo " 2) Análise de viabilidade (quanto posso ganhar)"
  echo " 3) Ver quem está usando o /home"
  echo " 4) Limpeza segura para liberar espaço no /"
  echo " 5) Salvar backup dos metadados (fstab, partições, LVM)"
  echo " 6) EXECUTAR: diminuir /home e aumentar /"
  echo " 7) Mostrar estado atual (lsblk, df, lvs)"
  echo " 0) Sair"
  echo "----------------------------------------------"
  read -r -p "Escolha uma opção: " op
  echo
  case "$op" in
    1) rodar diagnostico ;;
    2) rodar viabilidade ;;
    3) rodar usando_home ;;
    4) rodar limpeza ;;
    5) rodar salvar_metadados ;;
    6) rodar executar ;;
    7) rodar estado_atual ;;
    0) echo "Saindo."; exit 0 ;;
    *) warn "Opção inválida."; sleep 1 ;;
  esac
done