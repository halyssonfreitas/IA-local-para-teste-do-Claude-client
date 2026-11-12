# Redimensionar `/` e `/home` (Ubuntu, LVM)

`dignosticos.sh` é um menu interativo que ajuda a analisar e, se necessário, redimensionar partições em sistemas que usam LVM. Ele pode:
- Diagnosticar a configuração de partições, LVM e espaço livre.
- Calcular quanto espaço pode ser transferido de `/home` para `/`.
- Limpar pacotes e logs para liberar espaço.
- Realizar o redimensionamento (diminuição de `/home` e extensão de `/`).

**Atenção:** Essa ferramenta faz alterações críticas no layout de disco. **Faça backup completo** antes de prosseguir.

## Como usar
```bash
chmod +x dignosticos.sh
./dignosticos.sh
```

O script solicitará confirmação em cada passo e só executará mudanças se você confirmar. É necessário `sudo` para operações de disco.
