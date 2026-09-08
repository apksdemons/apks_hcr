# HCR / SpeiGo VPN Manager PRO v1.5.2 STATUS-TOP AUTO-TUNE MULTI-PORT (amd64)

Manager profesional para el binario oficial **hcr-server 0.0.3 - Patch 1**.

Esta versión mantiene el MULTI-PORT y el HEALTH FIX de v1.4.1 y agrega **AUTO-TUNE por CPU/RAM/listeners**.

## Cambio visual v1.5.2

El bloque de estado del HCR ahora aparece **arriba de las opciones del menú**. Se muestran primero el listener principal, los puertos HCR adicionales y el resumen AUTO-TUNE; después aparecen las opciones `[1]..[14]`. Este cambio es únicamente de presentación: no modifica listeners, systemd, AUTO-TUNE, firewall, `MAX_DOWNLOAD_FRAME`, `DOWNLOAD_POLL_TIMEOUT` ni el binario HCR.

## Abrir el menú

```bash
sudo ./install.sh
```

o:

```bash
sudo ./install.sh menu
```

## Perfil HCR recomendado para SpeiGo

- Transport: `plain`
- Puerto principal sugerido: `8880` (editable)
- `MAX_DOWNLOAD_FRAME=16384`
- `DOWNLOAD_POLL_TIMEOUT=8s`
- SSH target: `127.0.0.1:22`

El AUTO-TUNE **no modifica el protocolo HCR ni estos parámetros de transporte**.

## AUTO-TUNE v1.5.2

El manager detecta automáticamente:

- vCPU online
- RAM total
- cantidad de listeners HCR administrados (principal + extras)

Y calcula por listener:

- `LimitNOFILE`
- `TasksMax`
- `MemoryHigh`
- `MemoryMax`

El objetivo es eliminar los límites fijos de v1.4.1 (`NOFILE=4096`, `TasksMax=512`, `MemoryMax=384M`) sin consumir de forma ciega toda la VPS.

El sistema deja una reserva para Linux/SSH/kernel y reparte el resto entre todos los listeners HCR. Al agregar o eliminar un puerto HCR adicional, los recursos se recalculan y los listeners se reinician **secuencialmente**, validando después que cada uno permanezca `active`, mantenga PID estable y tenga su TCP en `LISTEN`.

### Ejemplo orientativo: VPS 6 vCPU / 12 GB RAM

Con 1 listener aproximadamente:

- `LimitNOFILE=98304`
- `TasksMax=3072`
- `MemoryHigh≈7.2 GB`
- `MemoryMax≈9.6 GB`

Con 4 listeners aproximadamente por listener:

- `LimitNOFILE=32768`
- `TasksMax=1024`
- `MemoryHigh≈1.8 GB`
- `MemoryMax≈2.4 GB`

Los valores reales se muestran en el menú y dependen del sistema detectado.

> AUTO-TUNE aumenta la capacidad disponible del proceso, pero no promete una cantidad exacta de usuarios: el límite real también depende de CPU steal, ancho de banda, peering, latencia, SSH y carga de cada usuario.

## MULTI-PORT REAL

Después de instalar el HCR principal con la opción **[1]** o **[2]**, usa:

- **[5] Agregar puerto HCR adicional [LISTENER REAL]**
- **[6] Eliminar puerto HCR adicional**
- **[7] Ver puertos HCR activos**

Ejemplo:

- Principal: TCP `8880`
- Extra: TCP `8080`
- Extra: TCP `9000`

Cada puerto crea un servicio systemd real:

```text
hcr-server.service
hcr-server-extra-8080.service
hcr-server-extra-9000.service
```

## Arranque después de reiniciar la VPS

El principal y cada puerto adicional se crean con:

- `systemctl enable`
- `WantedBy=multi-user.target`
- `Wants=network-online.target`
- `After=network-online.target`

Por eso, tras reiniciar la VPS, systemd vuelve a levantar automáticamente todos los listeners HCR administrados tan pronto como la red está disponible.

También usan reinicio automático y comprobación de salud para detectar procesos que no permanecen escuchando.

## Menú principal

```text
[1]  Instalación rápida HCR Plain :8880 [16384 / 8s]
[2]  Instalación personalizada principal
[3]  Cambiar puerto HCR principal
[4]  Cambiar transport HCR principal
[5]  Agregar puerto HCR adicional [LISTENER REAL]
[6]  Eliminar puerto HCR adicional
[7]  Ver puertos HCR activos
[8]  Abrir puerto TCP solo en firewall
[9]  Cerrar puerto TCP solo en firewall
[10] Estado completo HCR
[11] Reiniciar HCR principal + extras
[12] Ver registros HCR
[13] Desinstalar HCR completo
[14] Recalcular AUTO-TUNE CPU/RAM
[0]  Salir
```

La opción **[14]** es útil si aumentas o reduces vCPU/RAM de la VPS después de instalar HCR.

## Diferencia importante

**Agregar puerto HCR adicional** crea un listener HCR real y funcional.

**Abrir puerto TCP solo en firewall** únicamente modifica UFW/firewalld y no inicia un listener HCR.

## Uso directo sin menú

```bash
sudo ./install.sh --port 9000 --transport plain --max-download-frame 16384 --download-poll-timeout 8s
```

## TLS / Auto

Para `tls` o `auto`, coloca junto a `install.sh`:

- `fullchain.pem`
- `privkey.pem`

## Launcher de un solo comando

Con `start.sh` en el repositorio:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/apksdemons/apks_hcr/refs/heads/main/start.sh)
```

El launcher actualiza `install.sh`, `hcr-server` y `README.md` en `/opt/speigo-hcr` y abre el menú.

## Health Fix conservado

Un puerto solo queda registrado como HCR funcional cuando:

1. systemd informa `active`;
2. mantiene el mismo PID en comprobaciones consecutivas;
3. el puerto TCP está realmente en `LISTEN`.

Si falla, no muestra un falso `[OK]`, elimina la unidad fallida y enseña `systemctl status` + journal.

## Seguridad de la optimización

v1.5.2 no modifica sysctl globales, TCP congestion control, SSH, iptables/nftables ni otros servicios de la VPS. La optimización se mantiene dentro de las unidades HCR administradas para reducir el riesgo de afectar la estabilidad del servidor.

## Estilo visual v1.5.2

Las líneas separadoras del menú usan el patrón `=×=×=×=...` y se muestran en amarillo/oro cuando la terminal soporta ANSI. No cambia la lógica HCR, AUTO-TUNE ni MULTI-PORT.
