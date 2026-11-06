# Protocolo del Razer Barracuda X Chroma (receptor USB-C)

Todo lo de esta página se verificó contra un audífono real con firmware **1.0.9** y receptor **1.4.0**.

## Dispositivo HID

| Campo | Valor |
|---|---|
| VID:PID | `1532:0574` |
| Interfaz | página primaria `0xFF13` (la colección incluye `0xFF14`, consumer, telefonía y LampArray `0x59`) |
| Canal de ajustes | reportes de **salida/entrada** ID `0x02`, 64 bytes, página `0xFF14` |
| LampArray | reportes de *feature* `0x31`–`0x36`, 6 LEDs (ver abajo) |

## Formato del paquete

```
byte  0     1     2     3..5      6         7     8     9        10      11    12     13…        62
      02    00    60    00 00 00  4+n       00    00    destino  código  00    n      datos…     XOR(0…61)
```

- **destino** (byte 9): `0x80` = audífono, `0x00` = receptor.
- **código** (byte 10): la propiedad para **GET**; la propiedad `| 0x80` para **SET**.
- En un GET se manda `n = 0` (byte 6 = `04`).
- **Checksum** (byte 62): XOR de los bytes 0 a 61.

Respuesta:

```
02  estado  60 00 00 00  len  00  80  destino  código  01  n  datos…
```

`estado` = `02` correcto, `05` rechazado. Si el audífono está apagado, las peticiones al destino `0x80` no reciben respuesta.

## Propiedades

| GET | SET | Nombre | Valores |
|---|---|---|---|
| `0x00` | – | Número de serie | ASCII, 15 bytes |
| `0x01` | – | Edition ID | `0` negro, `128` blanco, `129` verde translúcido, `130` negro translúcido, `131` transparente |
| `0x02` | – | Firmware | `mayor menor parche 00` |
| `0x04` | – | (desconocido, solo lectura) | |
| `0x13` | `0x93` | Preset de EQ | `07` Juego, `08` Música, `09` Película, `FF` Propio |
| `0x15` | `0x95` | Curva de EQ propia | 10 × `int8` en dB, de 31 Hz a 16 kHz; acepta ±12 |
| `0x18` | `0x98` | Sidetone encendido | `0` / `1` |
| `0x19` | `0x99` | Nivel de sidetone | `0`–`15` |
| `0x20` | – | Enlace inalámbrico | `1` enlazado; pregúntale al **receptor** (destino `0x00`) |
| `0x21` | – | Batería | `0`–`100` % |
| `0x27` | `0xA7` | No molestar | |
| `0x2A` | – | Cargando | `0` / `1` |
| `0x2C` | `0xAC` | Apagado automático | minutos, `0` = nunca |
| `0x40` | `0xC0` | Efecto Chroma | ver abajo |
| `0x41` | `0xC1` | Brillo Chroma | `0`–`255`; `0` apaga las luces |
| `0x43` | `0xC3` | Windows Dynamic Lighting | habilita el control por LampArray |
| `0x55` | `0xE9` | Micrófono silenciado | |
| `0x66` | `0xE6` | LED del receptor | |

## Efectos (`0xC0`)

| Efecto | Datos de SET | Lectura en `0x40` |
|---|---|---|
| Estático | `01 R G B` | `01 R G B` |
| Respiración, 1 color | `02 00 R G B` | `02 00 R G B` |
| Respiración, 2 colores | `02 00 R1 G1 B1 R2 G2 B2` | igual |
| Respiración aleatoria | `02` | `00` |
| Espectro | `03` | `03` |
| Ola / Rueda | `0C` (también acepta `04`) | `0C` |
| Reactivo al audio | `0A` | `0A` |
| Fuego, Luz de estrellas | `09`, `0D` | rechazados (`05`) |

## LampArray

6 LEDs de propósito «Accent», cada uno con 255 niveles por canal. `LampMultiUpdate` (`0x34`) acepta los datos, pero el firmware no pinta nada mientras Windows Dynamic Lighting (`0x43`) esté apagado. Synapseless no usa este canal.

---

# Protocolo estándar (ratones, teclados, laptops)

> 🧪 Sin probar en hardware: viene del controlador `rzDevice25` de Synapse 4 y coincide con openrazer.

Un solo *feature report* de 90 bytes, ID `0`, en la interfaz HID cuyo `MaxFeatureReportSize` es ≥ 90. Se escribe, se esperan unos 15 ms y se lee la respuesta.

```
byte  0       1            2-3          4         5            6       7    8…87         88              89
      estado  transacción  restantes    protocolo tamaño datos clase   id   argumentos   XOR(2…87)       00
```

- **Transacción:** Synapse la cicla de 0 a 30; los dongles «Linker» usan `0xE0 | n`.
- **Estado de la respuesta:** `02` correcto, `01` ocupado (volver a leer), `03` falló, `04` tiempo agotado, `05` no soportado.
- **Comandos:** van como `[tamaño, clase, id]`; los GET tienen el bit alto del id encendido.

| Comando | Tamaño, clase, id | Argumentos |
|---|---|---|
| Firmware | `02 00 81` | → `mayor menor` |
| Batería | `02 07 80` | → `[1]` 0–255 |
| Cargando | `02 07 84` | → `[1]` 0/1 |
| DPI (GET / SET) | `07 04 85` / `07 04 05` | `varstore xHi xLo yHi yLo 00 00` |
| Polling (GET / SET) | `01 00 85` / `01 00 05` | `01` 1000 Hz, `02` 500 Hz, `08` 125 Hz |

## Familias de iluminación

Synapse elige un controlador por modelo (`useFeature("rzDeviceType", …)` en `main_<pid>.js`):

| Familia | Controladores | Efecto | Brillo |
|---|---|---|---|
| Matriz extendida | `rzDevice25`, `rzDevice25LedMatrix` | `0F 02` · `01 00 <efecto> …` | `0F 84` / `0F 04` · `01 00 <valor>` |
| Estándar (legacy) | `rzDevice25Legacy*` | `03 0A` · `<efecto> …` | `03 83` / `03 03` · `01 05 <valor>` |
| Blade | `rzDevice25LedMatrixBlade*` | igual que legacy | `0E 84` / `0E 04` · `01 <valor>` |

| Efecto | Matriz extendida | Estándar |
|---|---|---|
| Apagado | `00 00 00 00` | `00` |
| Estático | `01 00 00 01 R G B` | `06 R G B` |
| Respiración | `02 01 00 01 R G B` | `03 01 R G B` |
| Respiración aleatoria | `02 00 00 00` | `03 03` |
| Espectro | `03 00 00 00` | `04` |
| Ola | `04 01 28 00` | `01 01` |
