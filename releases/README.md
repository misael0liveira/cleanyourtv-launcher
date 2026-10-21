# CleanYourTV Launcher v2.4 (Release)

**APK compilado em:** 2026-10-21  
**SHA256:** `ebd1851df881801a7b03c3b9e6d3192a6838c4b71ae6545bda5e64adb168ce4a`  
**Tamanho:** 394 KB  
**Target SDK:** API 34 (Android 14)  
**Min SDK:** API 26 (Android 8.0)

## Instalação

### Via script automatizado (recomendado)

```bash
TV_HOST=192.168.0.4 TV_PORT=43175 ./install-launcher.sh
```

### Instalação manual do APK pré-compilado

Se você já tem ADB configurado e só quer instalar o APK:

```bash
# Conectar à TV
adb connect <tv-ip>:<porta>

# Instalar o APK
adb install -r releases/cleanyourtv-launcher-v2.4.apk

# Iniciar o launcher
adb shell am start -W -n com.gathin.tvhome/.MainActivity

# Definir como Home padrão
adb shell cmd package set-home-activity --user 0 com.gathin.tvhome/.MainActivity

# Pressionar Home no controle remoto da TV
adb shell input keyevent KEYCODE_HOME
```

### Desabilitar o launcher anterior (opcional)

Depois de confirmar que o novo launcher funciona:

```bash
# Listar launchers instalados
adb shell cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME

# Desabilitar o anterior (exemplo: FLauncher)
adb shell pm disable-user --user 0 me.efesser.flauncher
```

## Compilado a partir de

- **Repositório:** [Gathin23/cleanyourtv](https://github.com/Gathin23/cleanyourtv)
- **Commit:** compatível com a versão 2.4
- **Plataforma de build:** ARM64 (aarch64) com emulação qemu para aapt2
- **Gradle:** 8.10.2
- **AGP:** 8.5.2
- **Java:** 17

## Verificação

Para verificar a integridade do APK:

```bash
sha256sum releases/cleanyourtv-launcher-v2.4.apk
# Deve retornar: ebd1851df881801a7b03c3b9e6d3192a6838c4b71ae6545bda5e64adb168ce4a
```

## Notas de segurança

- APK **não assinado** (debug/release unsigned)
- Compilado localmente, não pela Play Store
- Código-fonte disponível no repositório original
- Use por sua conta e risco

## Restauração

Se quiser voltar ao launcher anterior:

```bash
# Reabilitar o launcher anterior
adb shell pm enable <pacote-do-launcher-anterior>

# Definir como Home
adb shell cmd package set-home-activity --user 0 <pacote>/<activity>
```
