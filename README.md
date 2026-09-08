# HCR / SpeiGo VPN Manager PRO v1.3.0 (amd64)

Manager interactivo profesional para el binario oficial **hcr-server 0.0.3 - Patch 1**.

## Abrir el menú

```bash
sudo ./install.sh
```

También acepta:

```bash
sudo ./install.sh menu
```

## Perfil rápido recomendado para SpeiGo

- Transport: `plain`
- Puerto sugerido: `8880` (editable; no es obligatorio)
- `MAX_DOWNLOAD_FRAME=16384`
- `DOWNLOAD_POLL_TIMEOUT=8s`
- SSH target: `127.0.0.1:22`

El menú permite instalación rápida, instalación personalizada, cambio de puerto, cambio de transport, firewall, estado, reinicio, logs y desinstalación. La instalación personalizada incluye los ajustes Frame/Poll.

## Uso directo sin menú

```bash
sudo ./install.sh --port 9000 --transport plain --max-download-frame 16384 --download-poll-timeout 8s
```

## TLS / Auto

Para `tls` o `auto`, coloca junto a `install.sh`:

- `fullchain.pem`
- `privkey.pem`

La clave privada debe ser accesible solo por root (por ejemplo `chmod 600 privkey.pem`).

## Firewall

Las opciones Abrir/Cerrar puerto soportan UFW y firewalld cuando están activos. Si la VPS usa firewall externo del proveedor, el manager informa que debes abrir el puerto también en ese panel.

## Rendimiento

Presets del menú:

- 16384: máximo rendimiento / recomendado
- 12288: balanceado
- 8192: conservador
- 6144: perfil anterior / rollback

Para SpeiGo CODE148 actual se recomienda conservar `DOWNLOAD_POLL_TIMEOUT=8s`.
