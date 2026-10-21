# Resumo executivo: instalação do CleanYourTV

Transcrição de uma sessão de instalação real do launcher CleanYourTV numa **KTC AIWA 2K SA-21V2** (Android TV 14, ARM64).

## O que está nesta pasta

| Ficheiro | Conteúdo |
|---|---|
| **`install-launcher.sh`** | Script automatizado para compilar e instalar o launcher. Funciona em ARM64 (deteta, instala qemu, monta sysroot x86_64). Uso: `TV_HOST=<ip> ./install-launcher.sh` |
| **`GUIA-COMPLETO.md`** | Documentação completa: análise do repositório CleanYourTV, diagnóstico dos erros (aapt2, ADB), solução ARM64, ordem de instalação, lições aprendidas |
| **`examples/ktc-stanford-sa-21v2/`** | Modelo específico desta TV: `debloat.txt` (pacotes desabilitados), `config.json` (dock de 4 apps), formato igual ao do repositório original |

## Como usar

### Se a sua TV é diferente desta

1. **Clone** o repositório oficial: `git clone https://github.com/Gathin23/cleanyourtv.git`
2. **Adapte** o script desta pasta ou siga os passos do `GUIA-COMPLETO.md`, capítulo 4.
3. **Leia** `examples/` no repo — há 120+ modelos testados. Se o seu modelo já está lá, use o `debloat.txt` dele.

### Se a sua TV é ARM64 e o build falha com "AAPT2 Daemon startup failed"

Use o `install-launcher.sh`. Ele resolve o problema automaticamente (instala qemu, monta o sysroot x86_64, cria o wrapper).

Ou faça manualmente — o capítulo 2 do `GUIA-COMPLETO.md` detalha cada passo.

### Se o ADB diz "No route to host" mas a rede está OK

```bash
adb kill-server && adb start-server && adb connect <ip>:<porta>
```

O servidor ADB fica com uma rota obsoleta. Capítulo 3 do guia explica o diagnóstico.

## Três pontos-chave

1. **A ordem de instalação importa:** instalar → iniciar → definir o Home → desabilitar o antigo.
   O script do repositório (`launcher/build-and-install.sh`) já acerta a ordem, mas assume que o build funciona — em ARM64 **não funciona** sem emulação.

2. **O aapt2 do SDK Android é x86_64-only.** Em ARM64 o build é impossível sem qemu. A mensagem `AAPT2 Daemon startup failed` **não** significa SDK corrompido — significa loader dinâmico em falta.

3. **Desabilitar ≠ desinstalar.** O CleanYourTV usa `pm disable-user`, nunca remove nada. Um `restore.sh` desfaz tudo. É por isso que é seguro.

## O resultado final

- **Ecrã inicial preto** com dock de 4 apps (TV ao vivo, Netflix, YouTube, Prime Video).
- **Grelha de apps** que desliza para cima quando se pressiona para baixo.
- **Screensaver do launcher:** um relógio minimalista a drift no ecrã, com uma auréola de cor lenta, para não queimar o ecrã.
- **O FLauncher desabilitado:** o botão Home já não abre dois launchers — só o nosso.
- **MultiMediaPlayer e Wi-Fi Display desabilitados** (a pedido).

## Pontos de atenção ao generalizar

- O mesmo nome de pacote pode ter funções diferentes em firmwares diferentes. O `com.mediatek.androidbox` nesta TV é o Wi-Fi Display — no modelo AIWA do repo é "remote pairing" (KEEP). **Verificar o `codePath` antes de desabilitar.**
- Se a rede Wi-Fi salva pertence ao `setupwraith`, desabilitá-lo **apaga a rede** e a TV sai do Wi-Fi. Verificar donos da rede antes (`dumpsys wifi | grep cname`).
- Se o `live_tv_package` estiver desabilitado, o tile do Live TV no launcher não abre nada. O `examples/ktc-stanford-sa-21v2/debloat.txt` comenta `com.mediatek.wwtv.tvcenter` (não desabilitar).

## Referências

- Repositório oficial: [github.com/Gathin23/cleanyourtv](https://github.com/Gathin23/cleanyourtv)
- `PROMPT.md` do repo — o prompt que o autor usa com assistentes de código
- `docs/TROUBLESHOOTING.md`, `docs/REMOTE.md` no repositório
- `examples/aiwa-ai-pont-sa/debloat.txt` — o modelo mais bem documentado

---

**Nota sobre a contribuição:** O `examples/ktc-stanford-sa-21v2/` segue o formato do repositório original, mas esta TV **não estava** no repo quando esta sessão aconteceu. Se o quiser contribuir, faça um fork do repo, adicione a pasta `examples/ktc-stanford-sa-21v2/` e abra um pull request.
