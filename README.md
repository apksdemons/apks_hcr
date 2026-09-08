# HCR / SpeiGo VPN Manager PRO v1.4.1 MULTI-PORT HEALTH FIX (amd64)

Manager profesional para el binario oficial **hcr-server 0.0.3 - Patch 1**.

## Abrir el menú

```bash
sudo ./install.sh
```

o:

```bash
sudo ./install.sh menu
```

## Perfil rápido recomendado para SpeiGo

- Transport: `plain`
- Puerto principal sugerido: `8880` (editable)
- `MAX_DOWNLOAD_FRAME=16384`
- `DOWNLOAD_POLL_TIMEOUT=8s`
- SSH target: `127.0.0.1:22`

## MULTI-PORT REAL

Después de instalar el HCR principal con la opción **[1]** o **[2]**, usa:

- **[5] Agregar puerto HCR adicional [LISTENER REAL]**
- **[6] Eliminar puerto HCR adicional**
- **[7] Ver puertos HCR activos**

Ejemplo:

- Principal: TCP `8880`
- Extra: TCP `8080`
- Extra: TCP `9000`

Cada puerto adicional crea su propio servicio systemd:

```text
hcr-server.service
hcr-server-extra-8080.service
hcr-server-extra-9000.service
```

Todos ejecutan el mismo `hcr-server` oficial, pero cada uno escucha realmente en su puerto. No se trata únicamente de abrir reglas de firewall.

Por defecto un puerto adicional hereda del principal `transport`, `MAX_DOWNLOAD_FRAME` y `DOWNLOAD_POLL_TIMEOUT`. El manager permite personalizar estos parámetros si se desea.

El firewall UFW/firewalld se abre automáticamente al crear cada listener adicional cuando está activo.

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
[0]  Salir
```

## Diferencia importante

**Agregar puerto HCR adicional** crea un listener HCR real y funcional.

**Abrir puerto TCP solo en firewall** únicamente modifica UFW/firewalld y no inicia un listener HCR.

## Uso directo del puerto principal sin menú

```bash
sudo ./install.sh --port 9000 --transport plain --max-download-frame 16384 --download-poll-timeout 8s
```

## TLS / Auto

Para `tls` o `auto`, coloca junto a `install.sh`:

- `fullchain.pem`
- `privkey.pem`

## Launcher de un solo comando

Si el repositorio contiene `start.sh`, el menú puede abrirse con:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/apksdemons/apks_hcr/refs/heads/main/start.sh)
```

El launcher actualiza `install.sh`, `hcr-server` y `README.md` en `/opt/speigo-hcr` y abre el menú.


## Corrección v1.4.1

- Corrige el falso `[OK]` que podía aparecer después de fallar la comprobación de un puerto adicional.
- Un listener extra solo queda registrado cuando `systemd` está `active`, mantiene el mismo PID y el puerto TCP está realmente en `LISTEN` durante 3 comprobaciones consecutivas.
- Si no se estabiliza, muestra diagnóstico real (`systemctl status` + journal), elimina la unidad fallida y no deja un puerto fantasma en el manager.
- La espera de salud tolera el tiempo normal de arranque de systemd, evitando falsos negativos por revisar el PID demasiado pronto.
- Se silencian warnings de `systemd-analyze` originados por servicios ajenos instalados en la VPS, como BADVPN; no se confunden con errores HCR.
- El motor oficial `hcr-server` y el perfil de rendimiento permanecen sin cambios.
