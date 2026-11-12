# GPU Activation Scripts

Esta pasta contém três utilitários de diagnóstico e ativação de GPU para distribuições Ubuntu (principalmente Debian‑based). Eles são voltados a usuários que desejam garantir que os drivers e a aceleração 3D estejam funcionando corretamente, antes de usar modelos de linguagem locais em GPU.

## Scripts
| Arquivo | Função | Uso típico |
|---------|--------|------------|
| `amd-setup.sh` | Diagnóstico completo da GPU AMD e instruções para habilitar o driver `amdgpu` (inclui instalador de utilitários e PPA) | `chmod +x amd-setup.sh && ./amd-setup.sh` |
| `intel-setup.sh` | Similar ao script AMD, mas para GPUs Intel (iGPU) – verifica drivers e configurações de BIOS. | `chmod +x intel-setup.sh && ./intel-setup.sh` |
| `nvidia-setup.sh` | Diagnóstico e instalação de drivers NVIDIA, incluindo suporte ao NVIDIA Container Toolkit para Docker. | `chmod +x nvidia-setup.sh && ./nvidia-setup.sh` |

> **Nota:** Os scripts pedem permissões `sudo` quando necessário. Eles são desenhados para execução em linha de comando, sem interface gráfica. Certifique‑se de ter um backup caso o script faça alterações críticas no sistema.

## Como usar
1. Faça download da pasta ou clone o repositório.
2. Dê permissão de execução ao script desejado:
   ```bash
   chmod +x <script>.sh
   ```
3. Execute-o como usuário normal (o script solicitará `sudo` quando preciso):
   ```bash
   ./amd-setup.sh
   ```
4. Siga as instruções na tela – o script apresentará um menu interativo e opções para instalar ou remover drivers, PPA, etc.

Os scripts não fazem mudanças permanentes sem sua confirmação, exceto em caso de erros críticos, que abortam a execução.
