# Guia completo: instalar o CleanYourTV launcher numa TV Android/Google TV

Documento de trabalho de uma sessão real de instalação, na TV **KTC AIWA 2K SA-21V2**
(`SMART_TV`, Android 14 / API 34, MediaTek). Reúne a análise do repositório base,
os erros que encontramos, as soluções e o script automatizado.

---

## 1. O repositório base

**CleanYourTV** (`Gathin23/cleanyourtv`) — fork/customização do FLauncher
(`me.efesser.flauncher`), empacotado como projeto Android TV launcher em Java
(pacote `com.gathin.tvhome`).

### Por que este repositório

A README promete o resultado final (tela inicial preta estilo Apple TV, dock de 4 apps,
sem anúncios) e o princípio de operação é simples e reversível:

> Disable com `pm disable-user`, nunca desinstala. Nada de root. Restauração em uma linha.

Esse detalhe — **desabilitar em vez de desinstalar** — é o que torna a coisa segura.
Nenhum pacote é removido do sistema, então `tools/restore.sh` desfaz tudo.

### Estrutura relevante

```
cleanyourtv/
├── launcher/                    # o app Android propriamente dito
│   ├── app/build.gradle         # AGP 8.5.2, compileSdk 34, minSdk 26, Java 17
│   ├── build-and-install.sh     # build + install + set-home (referência)
│   └── app/src/main/java/com/gathin/tvhome/
│       ├── MainActivity.java        # tela inicial
│       ├── ClockDream.java          # screensaver do launcher (relógio)
│       ├── HomeSettingsActivity.java, LauncherSettingsActivity.java
│       ├── QuickSettingsActivity.java, InputKeyService.java, HomeKeyService.java
│       ├── ThemeProvider.java, ThemeFiles.java  # temas / papel de parede
│       └── ... (AppAdapter, Cards, GridNavigation, RemoteKeys, Sky, Festival, ...)
├── tools/
│   ├── tv.py           # cliente ADB-over-TCP em Python puro (sem binário adb)
│   ├── disable.sh      # aplica uma lista de debloat
│   ├── restore.sh      # reabilita os pacotes de uma lista
│   ├── theme.sh        # aplica config.json (dock, apps ocultos, wallpaper)
│   ├── b64push.py      # envia arquivos grandes via base64
│   └── recovery.py     # recuperação após falha no meio do processo
├── examples/<modelo>/  # um diretório por modelo de TV testado
│   ├── debloat.txt     # lista de pacotes + comentários sobre o firmware
│   └── config.json     # dock e layout
└── docs/               # TROUBLESHOOTING, REMOTE, devices/, specs/
```

### O que `build-and-install.sh` já faz (e por que não bastou)

Lendo o script com atenção, a ordem das operações é deliberada e cada passo tem um
comentário explicando o risco que previne:

1. Descobre quem é o dono do Home **perguntando à TV** (`resolve-activity`), não adivinhando.
   Só desabilita launchers que ele reconhece numa lista branca; caso contrário aborta.
2. **Instala e só então desabilita o launcher stock** — se a instalação falhar, o stock fica intacto.
3. **Inicia o launcher e verifica `Status: ok`** antes de mexer no stock, porque `set-home-activity`
   sozinho resolve o componente sem provar que a activity sobe.
4. Faz rollback (`pm enable` + `set-home-activity`) se o Home não tiver ficado com o launcher novo.
5. Escreve um ficheiro de *handover* com os comandos de recuperação caso a conexão caia no meio.

O ponto que nos faltou: **o script assume que o build já funciona**. Foi aí que gastamos
a maior parte do tempo.

### O `debloat.txt` do modelo AIWA (referência útil)

O `examples/aiwa-ai-pont-sa/debloat.txt` é um exemplo extraordinariamente bem documentado —
comenta o que cada pacote faz, o que **não** deve ser desabilitado e por quê. Três lições
dele se aplicaram diretamente:

- `com.mediatek.androidbox` está na lista de **KEEP** (era o que o Wi-Fi Display usava).
- `com.mediatek.wwtv.tvcenter` é a app de **TV ao vivo** — não desabilitar.
- O `setupwraith` precisa de cuidado: se a rede Wi-Fi salva lhe pertence, desabilitá-lo
  **apaga a rede** e a TV sai do Wi-Fi.

---

## 2. O problema: build impossible em ARM64

### Sintoma

```
> Task :app:mergeReleaseResources FAILED
  > AAPT2 aapt2-8.5.2-11315950-linux Daemon #3: Daemon startup failed
    This should not happen under normal circumstances, please file an issue if it does.
```

Oito daemons, todos com o mesmo erro. A mensagem sugere um SDK corrompido — **não é**.

### Diagnóstico

```
$ od -An -j 18 -N 2 -t u2 .../aapt2
  62                    # e_machine = EM_X86_64

$ uname -m
aarch64                # este host é ARM64

$ .../aapt2 version
bash: cannot execute: required file not found
```

`required file not found` num ELF válido significa **loader dinâmico ausente**, não binário
corrompido. Confirmação: `/lib64/ld-linux-x86-64.so.2` não existe (o sistema é ARM64) e
`ldd` responde `not a dynamic executable`.

O `aapt2` do SDK (`/root/android-sdk/build-tools/34.0.0/aapt2`) tem o mesmo defeito — a
Google publica build-tools só para x86_64 Linux. O `sdkmanager` aceita o download, mas o
binário continua x86_64.

### Solução: emulação com qemu

Caminho percorrido, em ordem:

1. **`apt-get install qemu-user`** — dá `qemu-x86_64`.
2. **Sysroot x86_64 privado** em `/root/x86_64-root`. O `dpkg --add-architecture amd64`
   não serve: o Ubuntu Ports (mirror ARM) **não tem** pacotes `amd64` — todos os índices
   devolvem 404. A solução foi baixar os `.deb` diretamente de `archive.ubuntu.com`
   (que é amd64 puro) e extraí-los à mão:
   - `libc6_2.43-2ubuntu2_amd64.deb` → glibc
   - `libgcc-s1_16-20260322-1ubuntu1_amd64.deb` → `libgcc_s.so.1` (a falta dela dá
     `error while loading shared libraries: libgcc_s.so.1`)
3. **Symlink do loader**: o qemu procura `/lib64/ld-linux-x86-64.so.2` dentro do prefixo,
   e a glibc do Ubuntu extrai para `usr/lib/x86_64-linux-gnu/`. Sem o symlink:
   `qemu-x86_64: Could not open '/lib64/ld-linux-x86-64.so.2'`.
4. **Wrapper** em `/usr/local/bin/aapt2`:
   ```bash
   exec qemu-x86_64 -L /root/x86_64-root "$REAL_AAPT2" "$@"
   ```
5. **Override do Gradle** em `~/.gradle/gradle.properties`:
   ```
   android.aapt2FromMavenOverride=/usr/local/bin/aapt2
   ```
   Global, deliberadamente **fora** do repositório — o repo fica limpo para quem não usa ARM64.

### Erro que cometemos pelo caminho (e como se manifesta)

O primeiro wrapper fazia `find ~/.gradle/caches -name aapt2` a cada invocação. O Gradle
inicia **7 daemons aapt2 em paralelo**, cada um a percorrer o cache inteiro. O resultado não
era um erro, era um **timeout silencioso**:

```
AAPT2 bin Daemon #3. Not ready within 30 seconds.
```

O sintoma enganava: a mensagem fala em daemon que não arranca, mas o aapt2 estava a arrancar
demasiado devagar. **Diagnóstico**: medir o wrapper isolado com `time`. Passou de ">30s" para
**0.5s** quando o caminho foi fixado no script em vez de ser procurado em cada execução.

Regra que daí saiu: **no wrapper, caminho fixo sempre.** Nunca procurar em cada chamada.

### Verificação do modo daemon

O Gradle não usa o aapt2 em modo one-shot — usa o **protocolo de daemon** (stdio com
`Ready` / `Exiting daemon`). Precisava de um teste próprio:

```bash
$ printf 'version\n' | /usr/local/bin/aapt2 daemon
Ready
Exiting daemon
```

Só depois disso o build passou. Testar `aapt2 version` e supor que o daemon funciona
teria custado outro ciclo de debug.

### Resultado

```
BUILD SUCCESSFUL in 2m 50s
app-release.apk   394K
```

---

## 3. O problema: ADB "No route to host" com a rede OK

### Sintoma

```
$ adb connect 192.168.0.3:38325
failed to connect to '192.168.0.3:38325': No route to host
```

O endereço estava errado (a TV mudou de IP), então o primeiro erro era legítimo. Mas
quando o IP correto chegou (`192.168.0.4:43175`), o mesmo erro continuou — e aí já era falso.

### Diagnóstico

```
$ bash -c 'timeout 10 bash -c "</dev/tcp/192.168.0.4/43175"' && echo "TCP OK"
TCP OK
```

O socket TCP abre. A rede está boa; o **servidor ADB** é que tinha uma rota obsoleta em cache.

```
$ adb kill-server && adb start-server && adb connect 192.168.0.4:43175
connected to 192.168.0.4:43175
```

O `adb server` foi lançado antes de a rota de rede estar pronta e ficou com um estado ruim.
Reiniciá-lo resolveu.

Regra: **antes de suspeitar da rede, teste o socket com `/dev/tcp`**. Se o TCP abre e o ADB
falha, é o servidor ADB, não a rede.

Nota de ambiente: este host é Termux/PRoot e não tem `ip`, `ping`, `nc` nem `ifconfig`.
`ping` existe mas é o do Android (`/system/bin/ping`) e falha com `Operation not permitted`.
`/proc/net/route` e `/proc/net/dev` dão `Permission denied`. O `curl` e o `/dev/tcp` do bash
funcionam — foram as ferramentas de diagnóstico que restaram.

---

## 4. A instalação em si

### Ordem deliberada

O `build-and-install.sh` do repositório acerta a ordem, e vale respeitá-la:

1. **Instalar** (`pm install -r`) — o launcher stock continua intocado.
2. **Iniciar** (`am start -W`) e exigir `Status: ok` — `set-home-activity` resolve o
   componente, mas não prova que a activity sobe.
3. **Definir como Home** (`cmd package set-home-activity`).
4. **Só então desabilitar** o launcher anterior.

### Desabilitar o FLauncher

O FLauncher (`me.efesser.flauncher`) era o dono do Home. Desabilitá-lo **só depois** de o
nosso launcher estar instalado e a funcionar:

```
$ pm disable-user --user 0 me.efesser.flauncher
Package me.efesser.flauncher new state: disabled-user
```

Confirmação por `dumpsys package`: `enabled=3` (DISABLED_USER). Valores que importam:
`enabled=0` habilitado (default), `enabled=1` habilitado mas fora do launcher,
`enabled=2` desabilitado, `enabled=3` desabilitado para o utilizador.

### Dois apps que o utilizador pediu para desabilitar

| App | Pacote | APK |
|---|---|---|
| MultiMediaPlayer | `com.mediatek.wwtv.mediaplayer` | `/system_ext/priv-app/MultiMediaPlayerKtc/` |
| Wi-Fi Display Slink | `com.mediatek.androidbox` | `/system_ext/app/WFDSinkTest/` |

Cada package pode ter **várias entradas** no `dumpsys` (uma por código/apk instalado, uma
por apk de sistema). Importa ler a entrada certa: a do apk **de sistema** é a que tem
`installed=true` e um `codePath` real. A entrada `installed=false` é o registo do apk
pré-carregado pelo `/data`, já desinstalado.

**Contradição com o repositório que vale a pena registar:** o `debloat.txt` do AIWA lista
`com.mediatek.androidbox` na secção **KEEP** (justificativa: "Live TV, inputs, remote
pairing"). Na nossa TV (outro firmware, `KTC_AIWA_2K_SA_21V2`) o pacote **é** o
WFDSinkTest, ou seja, o Wi-Fi Display — e o utilizador quer desativá-lo. O mesmo nome de
pacote tem funções diferentes entre firmwares. A regra que distingo:

> **Nunca desabilite um pacote só porque o nome sugere bloat.** Verifique sempre o `codePath`
> e a atividade principal antes.

### Verificação final

```
Home:       com.gathin.tvhome/.MainActivity
After HOME: topResumedActivity=ActivityRecord{... com.gathin.tvhome/.MainActivity ...}
```

Sem entradas no `logcat -b crash` que mencionem `gathin`.

---

## 5. Sobre o Google Fotos como screensaver

Pergunta do utilizador, resposta apurada no dispositivo:

- A TV já tem `screensaver_components = com.google.android.backdrop/.Backdrop`.
- O **Backdrop** é um `DreamService` do Google — mostra cenários/arte, **não** fotos do
  utilizador.
- O **Google Photos não está instalado** na TV (`pm list packages | grep photos` → vazio).
- O Backdrop **não tem** nenhuma activity de settings (`cmd package query-activities` →
  `No activities found`), logo não há interface para ligar uma conta do Google Photos.

Conclusão honesta: **não é possível ter o Google Fotos como screensaver nesta TV sem
instalar um app de terceiros** que implemente um `DreamService` a ler do Google Photos.
Alternativas: um app de "Photo Screensaver" / "Aerial Dream" da Play Store, escolhido em
Configurações → Device Preferences → Screen saver.

---

## 6. O script

`install-launcher.sh` (nesta pasta) automatiza o processo inteiro:

```bash
TV_HOST=192.168.0.4 ./install-launcher.sh
```

O que ele faz, e o que acrescenta ao `build-and-install.sh` do repo:

1. **Detecta a arquitectura** e, em ARM64, instala o qemu, monta o sysroot x86_64
   e cria o wrapper do aapt2 (todo o capítulo 2, automatizado).
2. **Compila** o launcher.
3. **Conecta** à TV, com o *workaround* do `adb kill-server` (capítulo 3).
4. **Instala, inicia, define o Home** — pela mesma ordem segura do script original.
5. **Desabilita o launcher anterior**, exceto o nosso e o fallback do Android
   (`com.android.tv.settings`), para nunca deixar a TV sem Home.
6. **Desabilita pacotes extra** via `EXTRA_DISABLE`.
7. **Verifica** — Home resolvido, botão HOME a abrir o launcher, buffer de crashes vazio.

Variáveis de ambiente:

| Variável | Efeito |
|---|---|
| `TV_HOST` | IP da TV (obrigatório) |
| `TV_PORT` | porta ADB (predefinição 5555) |
| `REPO` | caminho do checkout do cleanyourtv |
| `DISABLE_PREV_LAUNCHER=0` | manter o launcher anterior activo |
| `EXTRA_DISABLE="pkg1 pkg2"` | pacotes adicionais a desabilitar |
| `SKIP_BUILD=1` + `APK=...` | instalar um APK já compilado |

---

## 7. Resumo das lições

**Sobre o build**
1. `AAPT2 Daemon startup failed` não significa SDK corrompido — significa loader dinâmico
   em falta. `od` no offset 18 do ELF diz a arquitetura real do binário.
2. A Google publica build-tools Android **só para x86_64 Linux**. Em ARM64 o build é
   impossível sem emulação.
3. O Ubuntu Ports não tem pacotes `amd64` — os índices devolvem 404. `archive.ubuntu.com`
   é a fonte para binários x86_64.
4. No wrapper do aapt2, **fixe o caminho**. Procurar o binário a cada execução transforma
   7 daemons paralelos num timeout de 30 s que parece um problema do Gradle.
5. Teste o **modo daemon** do aapt2 explicitamente (`printf 'version\n' | aapt2 daemon`)
   antes de culpar o Gradle. É o modo que o build realmente usa.

**Sobre a rede**
6. `No route to host` do ADB com o TCP aberto = servidor ADB com rota obsoleta.
   `adb kill-server && adb start-server` resolve.
7. Neste ambiente (Termux/PRoot) faltam `ip`, `ping`, `nc`, `ifconfig`; `/proc/net/*` é
   ilegível. `/dev/tcp` do bash e o `curl` são as ferramentas de diagnóstico que sobram.

**Sobre a instalação**
8. Instalar → iniciar → definir Home → desabilitar o antigo. Sempre nessa ordem.
9. `set-home-activity` pode falhar em silêncio; `am start -W` + `Status: ok` é a prova.
10. `enabled=3` é "desabilitado para o utilizador" — o que `pm disable-user` faz.
11. O mesmo nome de pacote pode ter funções diferentes em firmwares diferentes
    (`com.mediatek.androidbox` = Wi-Fi Display aqui, "manter" no AIWA). **Verificar o
    `codePath` antes de desabilitar.**
12. Verificar os claimants de Home antes de desabilitar qualquer coisa, para nunca deixar
    a TV sem ecrã inicial.

**Sobre o repositório base**
13. O `debloat.txt` do AIWA é um modelo do nível de documentação a que vale a pena aspire:
    cada linha com o motivo e com a alternativa.
14. O `build-and-install.sh` do repo é sólido na parte de instalação e frágil na parte de
    build — assumes que `gradlew` funciona.
15. O `examples/` com 120+ modelos é o ativo mais valioso do repositório: mesmo nome de
    pacote, firmware diferente, comportamento diferente.

---

## 8. Referências

- Repositório: `https://github.com/Gathin23/cleanyourtv`
- FLauncher (base original): `https://github.com/flauncher/FLauncher`
- `PROMPT.md` do repo — o prompt que o autor usa com assistentes de código
- `docs/TROUBLESHOOTING.md`, `docs/REMOTE.md`, `docs/devices/` no repositório
