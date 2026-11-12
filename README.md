# Projeto "IA local para teste do Claude client"

Este repositório contém uma coleção de scripts auxiliares para configurar e usar **Claude Code** com modelos de linguagem locais (Ollama) ou externos (Anthropic API, OpenRouter, Vertex, Bedrock, etc.). Ele foi desenvolvido para quem deseja experimentar LLMs no seu próprio PC, em vez de pagar por uso em nuvem.

## Estrutura do repositório

```
├─ ativacao-de-gpu          # Scripts de diagnóstico e ativação de GPU (AMD, Intel, NVIDIA)
├─ diagnostico-da-maquina-host  # Diagnóstico rápido para escolher o modelo local
├─ discos                  # Menu para redimensionar / e /home (LVM) e limpar disco
├─ claude-llm-setup.sh     # Script principal – menu interativo de instalação e gerenciamento
└─ README.md               # Este arquivo
```

## Script principal – `claude-llm-setup.sh`

O arquivo **`claude-llm-setup.sh`** é o coração deste projeto. Ele oferece um menu interativo com as seguintes opções:

| Opção | Descrição |
|-------|-----------|
| 1 | Diagnóstico completo da máquina – hardware, Docker, GPU, rede, etc. |
| 2 | Instalação e correção de requisitos (Docker, GPU, ferramentas) |
| 3 | Instalação ou atualização do Claude Code |
| 4 | Desligar modelo local ativo |
| 5 | Subir modelo **LOCAL** em Docker (Ollama) – seleção do modelo e configuração de contexto |
| 6 | Adicionar modelo **EXTERNO** – Anthropic, OpenRouter, Vertex, Bedrock ou outro endpoint compatível |
| 7 | Gerenciar perfis de modelos (ativar, ver, remover) |
| 8 | Testar o perfil ativo com um prompt simples |
| 9 | Abrir o Claude Code no diretório escolhido |
| 0 | Sair |

### Como executar
```bash
chmod +x claude-llm-setup.sh
./claude-llm-setup.sh
```

> **Observação:** O script exige permissões `sudo` para instalar pacotes e gerenciar Docker. Ele solicitará confirmação antes de instalar qualquer coisa.

### Fluxo típico de uso
1. **Diagnóstico** (opção 1) para verificar se tudo está pronto.
2. **Instalar/Corigir requisitos** (opção 2) – Docker, GPU, ferramentas básicas.
3. **Instalar o Claude Code** (opção 3).
4. **Criar perfil local** (opção 5) – escolha um modelo, defina contexto e ative.
5. **Usar** – menu 9 abre o Claude Code ou menu 8 testa.

## Como contribuir
Se você quiser adicionar mais scripts, melhorar os existentes ou corrigir bugs, abra um PR. Siga a convenção de commit abaixo.

## Attributions (for commits/PRs)
- End git commit messages with: `Co-Authored-By: Claude Code <noreply@anthropic.com>`
- End pull request descriptions with: `🤖 Generated with [Claude Code](https://claude.com/claude-code)`

---

> **Nota**: Este repositório não faz uso de código de terceiros protegido; todos os scripts são de autoria própria.
