# Diagnóstico para LLMs locais

`diagnostico-llm.sh` é um script de diagnóstico rápido que coleta informações de hardware e estima a memória disponível para modelos de linguagem rodando localmente, seja em Docker (Ollama) ou em CPU.

## Funcionalidades
- Detecta CPU, RAM, GPU (NVIDIA, AMD, Apple, ou nenhuma) e tamanho de disco.
- Calcula a memória útil para o modelo (`FAST` e `SLOW`).
- Apresenta uma tabela de modelos compatíveis com o tamanho da memória disponível.
- Sugere a melhor opção de modelo local (ex.: `qwen3:8b`, `gpt-oss:20b`, etc.).
- Exibe instruções passo a passo para instalar e usar o modelo com Ollama.

## Como usar
```bash
chmod +x diagnostico-llm.sh
./diagnostico-llm.sh
```

O script é compatível com Linux e macOS (no Windows execute via WSL). Ele não altera nada no sistema, apenas lê informações.
