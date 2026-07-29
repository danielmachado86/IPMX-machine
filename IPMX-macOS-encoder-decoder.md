# Encoder/Decoder IPMX H.264 y H.265 mínimo viable en macOS

Documento de arquitectura y BOM. Basado en lectura directa de los PDF normativos de VSF
(TR-10-1, TR-10-7, TR-10-8, TR-10-15 Parts 2 y 3), descargados de vsf.tv en julio 2026.

Máquina de referencia asumida: MacBook Pro M4 Pro, 24 GB, macOS 26.5.

---

## 1. Qué documentos aplican realmente

IPMX **no** es un protocolo único: es un conjunto de deltas sobre SMPTE ST 2110 + NMOS.
Para vídeo comprimido H.264/H.265 la pila normativa exacta es:

| Documento | Estado | Aplica |
|---|---|---|
| **TR-10-1** System Timing and Definitions | Final 2024-02-23 | **Obligatorio.** Relojes, RTCP Sender Report, IPMX Info Block |
| **TR-10-7** Compressed Video | Draft 2024-11-22 | **Obligatorio.** Transporte RTP de vídeo comprimido no-CBR |
| **TR-10-15 Part 3** H.264 Codec Requirements | Draft 2026-06-04 | **Obligatorio** para H.264 |
| **TR-10-15 Part 2** H.265 Codec Requirements | Draft 2026-06-04 | **Obligatorio** para H.265 |
| **TR-10-8** NMOS Requirements | Final 2026-01-06 | **Obligatorio.** IS-04, IS-05, IS-11, BCP-004-01/02 |
| TR-10-11 Constant Bit-Rate Compressed Video | Final | **No aplica.** Es para códecs con bytes/frame constante (JPEG XS) |
| TR-10-2 Uncompressed Active Video | Final | Solo por referencia: el Media Info Block 0x0005 se define aquí |
| TR-10-3 PCM Audio | Final | Fuera de alcance del MVP |
| TR-10-5 HDCP Key Exchange / TR-10-13 PEP | Final | **Excluir del MVP** (ver §6) |
| TR-10-14 IPMX USB, TR-10-10 InfoFrames, TR-10-16 HDR | Draft | Fuera de alcance |

Y por debajo: RFC 3550 (RTP), **RFC 6184** (payload H.264), **RFC 7798** (payload H.265),
RFC 4566 (SDP), RFC 7273 (ts-refclk/mediaclk), **BCP-006-02** (NMOS con H.264),
**BCP-006-03** (NMOS con H.265), BCP-004-01/02 (capabilities).

> Nota de estado: TR-10-7 y TR-10-15 siguen en **Draft**. Cualquier cosa que construyas hoy
> es contra un blanco móvil. Fija la versión de cada PDF en el repo.

---

## 2. Requisitos técnicos que salen de las specs

Esto es lo que tu implementación tiene que cumplir. Lo extraigo aquí porque determina
directamente qué software puedes usar y qué tienes que escribir tú.

### 2.1 Transporte (TR-10-7)

- Payload format según **ST 2110-22 §6**.
- Reloj RTP y Media Clock a **90 kHz** (fijo, no negociable).
- Todos los paquetes RTP de un mismo frame progresivo comparten el **mismo RTP timestamp**.
- Puerto UDP destino **par**, `> 1024`, y **debería** ser `> 5000`.
- Tamaño UDP ≤ Standard UDP Size Limit de ST 2110-10 (típico 1460 bytes de payload).
- SDP según ST 2110-22 §7, con `b=AS:<kbps>` = bitrate máximo objetivo **incluyendo cabeceras IP**.
- **Traffic shaping**: modelo de compatibilidad de red de TR-10-1 §8.1, pero con
  `CMAX = MAX(16, INT(MaxRate / 21600))` donde `MaxRate` es el bitrate máximo en **paquetes/segundo**.
  El Virtual Receiver Buffer Model de ST 2110 **no aplica**.

### 2.2 Bitstream (TR-10-15 Parts 2 y 3)

Requisitos comunes a ambos códecs:

- `TP=2110TPW` declarado explícitamente en el `a=fmtp`.
- **HRD Type II obligatorio**: `nal_hrd_parameters_present_flag = 1`, parámetros HRD dentro
  de `vui_parameters()` del SPS, `cpb_cnt_minus1 = 0`.
- **Buffering Period SEI** en cada recovery point. **Picture Timing SEI** en cada access unit.
- VUI obligatorio con `video_signal_type_present_flag`, `colour_description_present_flag`,
  y timing info a 1. `num_units_in_tick` = denominador del framerate.
  (⚠ H.264: `time_scale` = **2×** numerador. H.265: `vui_time_scale` = numerador **sin ×2**.)
- **Decode order = output order.** `max_num_reorder_frames` / `sps_max_num_reorder_pics` = 0.
  B-frames permitidos solo con referencias pasadas.
- Random access point **cada ≤ 5 segundos** (IDR + SPS + PPS, y VPS en H.265).
- **Un solo VCL NAL unit por paquete UDP** (obliga a fragmentación FU-A/FU, prohíbe agregar
  varios slices en un STAP-A).
- H.264: prohibidos PAFF, Extended profile, ASO, FMO, RS, DP, SI, SP, y los Anexos F–J.
- H.265: prohibidos los paquetes PACI de RFC 7798.

Perfiles mínimos:

| | Sender debe producir | Receiver debe consumir |
|---|---|---|
| **H.264** | High **o** Main, 4:2:0, 8 bit | High **y** Main, 4:2:0, 8 bit, **hasta Level 4.2** |
| **H.265** | Main 8 bit 4:2:0 **o** Main10 4:2:0 8/10 bit | Main **y** Main10, **hasta Level 5.1 Main tier** |

### 2.3 RTCP — la parte que ninguna librería te da

Esto es lo más específico de IPMX y donde vas a escribir código propio sí o sí.

- RTCP Sender Report por cada frame, al puerto **media+1**, misma IP destino.
- Cada SR lleva una extensión **IPMX Info Block** (tag `0x5831` = `"X1"`), que contiene el
  string `ts-refclk` (64 bytes) y una lista de **Media Info Blocks**:
  - `0x0005` — vídeo (formato idéntico al de TR-10-2 §10)
  - `0x000A` — info específica de **H.264** (`profile-level-id`, `packetization-mode`,
    `sprop-parameter-sets`, …, con FIELD-PRESENT-MASK)
  - `0x0009` — info específica de **H.265** (`profile-space`, `profile-id`, `level-id`,
    `tier-flag`, `sprop-vps`, `sprop-sps`, `sprop-pps`, …)
- Los parámetros del Media Info Block deben usar **la misma sintaxis que la línea `a=fmtp`** del SDP.
- El SR va **antes** del primer paquete de media de su frame. `encoder_delay` y
  `sender_reports_delay` deben ser **constantes** una vez arrancado el stream. Si el encoder
  salta un frame, **no** puede saltar su Sender Report.

Ejemplo real de `a=fmtp` tomado de TR-10-15 Part 3:

```
a=fmtp:96 width=1920; height=1080; depth=10; exactframerate=60;
sampling=YCbCr-4:2:2; colorimetry=BT709; TP=2110TPW; MAXUDP=1460; TCS=SDR;
RANGE=NARROW; measuredpixclk=124416000; vtotal=1080; htotal=1920; IPMX;
profile-level-id=7A0028; packetization-mode=1
```

### 2.4 Reloj — el punto que hace viable macOS

TR-10-1 §7 es explícito: **un dispositivo IPMX debe funcionar tanto con como sin reloj común**.

- Sin PTP en la red: el Sender mantiene un **Internal Clock de marcha libre** y señaliza
  `a=ts-refclk:localmac` + `a=mediaclk:direct=0`.
- Con PTP: IEEE 1588-2008, perfil ST 2059-2, `defaultDS.slaveOnly = TRUE` por defecto.
  Sin requisito de trazabilidad y con exactitud de frecuencia del GM solo `< 100 ppm`.

Esto es la diferencia clave respecto a ST 2110 puro y es lo que permite un prototipo en un
Mac sin timestamping hardware. **Empieza en modo `localmac`.**

### 2.5 Plano de control (TR-10-8)

- **IS-04 v1.3** Node API, con DNS-SD **unicast y multicast** ambos soportados y habilitados.
  Si se descubre un Registration API por unicast, prohibido hacer browsing multicast.
- **IS-05 v1.1** connection management; el Sender expone su SDP en `/transportfile`.
- **IS-11** Stream Compatibility Management — obligatorio.
- **BCP-004-01** (Receiver Capabilities) y **BCP-004-02** (Sender Capabilities) para
  `video/H264` y `video/H265`.
- **BCP-005-01** para convertir EDID en Receiver Capabilities.
- **BCP-002-01/02** (natural grouping, distinguishing information).
- Extensión IS-05 `ext_link_offset_delay` en el Receiver, con soporte del valor `auto`.

---

## 3. Software

### 3.1 Reparto: qué existe vs. qué escribes tú

| Capa | Solución | Esfuerzo |
|---|---|---|
| Captura de vídeo | ScreenCaptureKit / AVFoundation / DeckLink SDK | Bajo — API nativa |
| Codificación | **x264 / x265** (ver 3.2) o VideoToolbox | Medio |
| Parcheo de SPS/VUI/HRD | **Propio** (bit-writer H.264/H.265) | Alto, si usas VideoToolbox |
| Paquetización RTP | GStreamer `rtph264pay`/`rtph265pay` o propio | Bajo–medio |
| **RTCP + IPMX Info Block** | **Propio, íntegro** | **Alto** |
| **Traffic shaper CINST/CMAX** | **Propio** | **Alto** en macOS |
| SDP gen/parse | Propio sobre plantilla | Bajo |
| NMOS IS-04/IS-05 | **sony/nmos-cpp** | Medio (integración) |
| NMOS IS-11 | **Propio** — no está en nmos-cpp | Alto |
| Decodificación | VideoToolbox (`VTDecompressionSession`) | Bajo |
| Render | `AVSampleBufferDisplayLayer` o Metal | Bajo |

Traducción: **entre el 40 % y el 50 % del trabajo es código que no existe en ningún sitio**
(RTCP con IPMX Info Block, el shaper, e IS-11). Lo demás es integración.

### 3.2 La decisión crítica: VideoToolbox vs. x264/x265

El M4 Pro tiene motor de vídeo dedicado con encode/decode hardware de H.264 y HEVC. Es la
opción obvia por latencia y consumo… pero:

**VideoToolbox no expone control de HRD/CPB ni inserción de Buffering Period SEI.**
`VTCompressionSession` te da `AverageBitRate`, `ConstantBitRate` (macOS 13+), `DataRateLimits`,
`ExpectedFrameRate`, `MaxKeyFrameInterval`, `ProfileLevel`, `AllowFrameReordering`… pero
**no** `nal_hrd_parameters`, ni `cbr_flag`, ni SEI arbitrarios. Y TR-10-15 exige HRD Type II
con Buffering Period y Picture Timing SEI. Sin eso, no eres conforme.

Salidas posibles:

1. **x264 / x265 vía libavcodec.** Ambos soportan HRD nativamente:
   `x264 --nal-hrd cbr|vbr` (requiere `--vbv-maxrate` + `--vbv-bufsize`) emite Buffering
   Period y Picture Timing SEI correctos. `x265 --hrd` hace lo equivalente.
   **Es el camino recomendado para la fase de conformidad.** Coste: CPU en vez de media engine.
2. **VideoToolbox + post-procesado de bitstream.** Codificas en hardware, parseas el SPS,
   reescribes `vui_parameters()` inyectando `hrd_parameters()`, y sintetizas las SEI de
   Buffering Period / Picture Timing tú mismo a partir de tu propio modelo de CPB.
   Es la ruta de producción, pero es trabajo de bitstream serio.

Lo que **sí** mapea limpio a VideoToolbox:
`kVTCompressionPropertyKey_AllowFrameReordering = false` te da directamente
decode order = output order y `max_num_reorder_frames = 0`. Perfiles Main/High y
Main/Main10 están soportados en hardware. Y el **decoder** no tiene ningún problema:
usa VideoToolbox sin reservas en el lado receptor.

> **Verifícalo empíricamente antes de decidir**: codifica 2 s con VideoToolbox, vuelca el SPS y
> parsea el VUI. Si `nal_hrd_parameters_present_flag` sale 0 (lo esperado), tienes confirmado
> el trabajo de parcheo.

### 3.3 Stack concreto recomendado

```
macOS 26 / Apple Silicon
├── Control plane
│   ├── sony/nmos-cpp .......... IS-04 v1.3 + IS-05 v1.1 + IS-08/09, BCP-002/003/004
│   │                            (compila en macOS; CMake + vcpkg o Homebrew)
│   ├── nmos-js ............... controlador/explorador NMOS en navegador, para pruebas
│   └── IS-11 ................. implementación propia sobre el mismo servidor HTTP
├── Descubrimiento
│   └── Bonjour nativo ........ mDNS/DNS-SD ya está en macOS (dns-sd, NSNetService)
├── Media plane
│   ├── GStreamer 1.24+ ....... rtph264pay/rtph265pay, rtpjitterbuffer, vtenc/vtdec, GstPtpClock
│   ├── FFmpeg/libav .......... libx264, libx265, h264_videotoolbox, hevc_videotoolbox
│   └── Módulos propios ....... RTCP SR + IPMX Info Block, traffic shaper, SDP
└── Validación
    ├── AMWA nmos-testing ..... suite de conformidad NMOS (Python)
    ├── EBU LIST .............. análisis de pcap ST 2110 (timing, CINST/CMAX)
    └── Wireshark ............. disector RTP/RTCP; escribirás un disector Lua para el Info Block
```

Instalación base:

```bash
brew install cmake ninja pkg-config ffmpeg gstreamer gst-plugins-base gst-plugins-good gst-plugins-bad x264 x265 wireshark poppler
```

### 3.4 Los cuatro problemas de macOS (y su mitigación)

**1. No hay pacing de paquetes en el kernel.**
macOS no tiene `SO_TXTIME` ni qdisc `etf` (eso es Linux). El shaper CINST/CMAX de §2.1 hay que
hacerlo en espacio de usuario: hilo dedicado con `thread_policy_set()` +
`THREAD_TIME_CONSTRAINT_POLICY` para scheduling real-time, y busy-wait sobre
`clock_gettime_nsec_np(CLOCK_UPTIME_RAW)`. `usleep()` no tiene la resolución necesaria.
Con H.264/H.265 a 20–50 Mbps el ritmo de paquetes es manejable; con vídeo sin comprimir sería
inviable.

**2. No hay timestamping hardware de PTP.**
macOS no expone `SO_TIMESTAMPING` (Linux-only) y las NIC USB/Thunderbolt no dan timestamps de
PHY. Solo tienes `SO_TIMESTAMP` software, con precisión de decenas de µs.
→ **Mitigación: arranca en modo `ts-refclk:localmac`** (permitido explícitamente por TR-10-1 §7.1).
Cuando necesites PTP, usa el `GstPtpClock` de GStreamer (cliente PTP software, requiere el
helper `gst-ptp-helper` con setuid para los puertos 319/320) o `ptpd`. Suficiente para vídeo
comprimido, insuficiente para ST 2110-21 narrow.

**3. Buffers de socket UDP pequeños por defecto.**
```bash
sudo sysctl -w net.inet.udp.recvspace=8388608
sudo sysctl -w kern.ipc.maxsockbuf=16777216
```
Y en el código: `SO_RCVBUF`, `SO_REUSEPORT`, `IP_MULTICAST_IF` explícito (crítico si hay varias
interfaces), `IP_ADD_MEMBERSHIP` con la interfaz correcta, y `IP_MULTICAST_LOOP` desactivado.

**4. El MacBook Pro no tiene Ethernet.**
Ver §4.2. Los adaptadores USB añaden jitter de bus; para el pacing importa.

---

## 4. Hardware

### 4.1 El Mac

Tu M4 Pro sobra para el MVP: motor de vídeo dedicado con H.264/HEVC encode y decode por
hardware, 12 núcleos para el camino x264/x265, y 24 GB de RAM. No necesitas comprar Mac.

Si esto va a producción y quieres una unidad fija: **Mac mini M4** (~700 €) — misma media
engine, **y Ethernet integrada** (10 GbE como opción de 100 €), lo que elimina el problema
del adaptador USB. Es la máquina correcta para un nodo IPMX dedicado.

### 4.2 Red

| Elemento | Mínimo | Recomendado | Por qué |
|---|---|---|---|
| NIC | Adaptador USB-C→GbE (~30 €) | **Sonnet Solo10G Thunderbolt 3** (~200 €) | El Thunderbolt es PCIe nativo (Aquantia AQC107): mucho menos jitter de TX que USB |
| Switch | Cualquiera con **IGMPv2/v3 snooping + querier** | Netgear **M4250** (~900 €) o Cisco CBS350 (~400 €) | Sin querier, el multicast se inunda o se cae. El M4250 además hace boundary clock PTP |
| Cableado | Cat6 | Cat6a | — |

Ancho de banda: H.264/H.265 1080p60 son **10–50 Mbps**. Gigabit va sobradísimo. El 10 GbE
solo lo necesitas si más adelante añades JPEG XS o vídeo sin comprimir.

### 4.3 Reloj PTP (opcional en el MVP)

Gracias a `ts-refclk:localmac` puedes saltarte esto por completo al principio. Cuando lo necesites:

- **Barato**: mini-PC x86 con NIC Intel i210/i225/X550 (timestamping hardware) + `linuxptp`
  (`ptp4l -f gPTP.cfg`) actuando de grandmaster. ~200 €. Nota que TR-10-1 solo exige
  **< 100 ppm** y no exige trazabilidad, así que no necesitas GPS.
- **Switch como GM**: el Netgear M4250 y equivalentes lo hacen.
- **Profesional**: Meinberg microSync, Evertz 5700MSC. 3.000 €+. Innecesario para desarrollo.

### 4.4 Entrada de vídeo (lado encoder)

| Opción | Precio | Nota |
|---|---|---|
| **ScreenCaptureKit / cámara** | 0 € | **Empieza aquí.** Sin hardware, sin drivers |
| Magewell USB Capture HDMI 4K Plus | ~350 € | **UVC puro, cero drivers en macOS.** La opción más limpia |
| Blackmagic UltraStudio Recorder 3G | ~150 € | Thunderbolt, HDMI+SDI in, requiere Desktop Video |
| AJA U-TAP HDMI/SDI | ~350 € | USB 3, UVC |

### 4.5 Salida de vídeo (lado decoder)

| Opción | Precio | Nota |
|---|---|---|
| **Ventana Metal / AVSampleBufferDisplayLayer** | 0 € | **Empieza aquí** |
| Blackmagic UltraStudio Monitor 3G | ~150 € | Thunderbolt, salida HDMI + SDI |

### 4.6 Validación

Esto es lo que la gente subestima. Sin esto no sabes si eres conforme.

- **Captura con timestamp hardware**: un PC Linux con NIC Intel i210 en un puerto SPAN del
  switch, `tcpdump -j adapter_unsynced`. **El Mac no puede capturar con precisión suficiente
  para validar su propio pacing** — necesitas un observador externo.
- **EBU LIST** (open source): come el pcap y valida timing ST 2110-21, CINST/CMAX, RTP.
- **AMWA nmos-testing**: suite oficial de conformidad IS-04/IS-05/IS-11/BCP-004.
- **Disector Lua para Wireshark**: tendrás que escribirlo para ver el IPMX Info Block
  (`0x5831`) y los Media Info Blocks `0x0005`/`0x0009`/`0x000A`. Unas 200 líneas, y te ahorrará
  semanas de depuración.
- **Interoperabilidad real**: en algún momento necesitas un dispositivo IPMX comercial contra
  el que probar (Macnica, Matrox ConvertIP, Nextera). Es la única prueba que vale.

---

## 5. Ruta de implementación

**Fase 0 — Bucle RTP puro (1–2 semanas).**
ScreenCaptureKit → x264 → paquetización FU-A RFC 6184 → UDP multicast → VideoToolbox decode →
ventana. Sin RTCP, sin NMOS, sin PTP. SDP escrito a mano. Objetivo: ver imagen.

**Fase 1 — Conformidad de bitstream (2–3 semanas).**
x264 con `--nal-hrd vbr --vbv-maxrate --vbv-bufsize`, VUI completo, un VCL NAL por paquete,
IDR cada ≤5 s, `TP=2110TPW`, reloj 90 kHz, puerto par >5000, decode order = output order.
Validar volcando y parseando el SPS.

**Fase 2 — RTCP + IPMX Info Block (2–3 semanas).**
Sender Report por frame en media+1, con el Info Block `0x5831` y los Media Info Blocks
`0x0005` + `0x000A`/`0x0009`. `encoder_delay` constante. Disector Lua en paralelo.

**Fase 3 — Traffic shaper (2 semanas).**
Hilo real-time, `CMAX = MAX(16, INT(MaxRate/21600))`. Validar con captura externa + EBU LIST.

**Fase 4 — NMOS (3–4 semanas).**
Integrar nmos-cpp, exponer Node/Device/Source/Flow/Sender/Receiver, SDP en
IS-05 `/transportfile`, BCP-004-01/02, `ext_link_offset_delay`. IS-11 al final: es el más caro.

**Fase 5 — H.265.**
Casi todo se reutiliza. Cambian RFC 7798 en vez de 6184, Media Info Block `0x0009`,
`vui_time_scale` sin ×2, prohibición de PACI, y VPS además de SPS/PPS.

**Estimación total**: 3–4 meses de un desarrollador con experiencia previa en RTP y bitstreams
H.26x. Sin esa experiencia previa, el doble.

---

## 6. Lo que debes dejar fuera del MVP, y por qué

- **HDCP (TR-10-5) y PEP (TR-10-13).** El intercambio de claves HDCP requiere ser **adoptante
  licenciado de DCP LLC** y recibir claves de dispositivo bajo NDA. No es un problema técnico,
  es contractual, y no lo puedes resolver escribiendo código. Además macOS no te va a entregar
  contenido protegido por HDCP desde su pipeline. Fuera.
- **Audio (TR-10-3), ANC (TR-10-4), USB (TR-10-14), InfoFrames (TR-10-10), FEC (TR-10-6).**
  Ortogonales al vídeo; añádelos después.
- **Interlazado.** TR-10-15 lo permite, pero duplica la complejidad de timestamps y `pic_struct`.
  Progresivo solo.
- **PTP.** Modo `localmac` mientras puedas.

---

## 7. Resumen ejecutivo

**Hardware, MVP: 0 €.** Tu MacBook Pro M4 Pro basta. Captura de pantalla como fuente, ventana
como destino, loopback o una LAN doméstica.

**Hardware, banco de pruebas serio: ~1.500 €.**
Sonnet Solo10G (200) + Netgear M4250 (900) + Magewell HDMI (350), más un PC Linux reciclado
con NIC Intel para capturar y validar.

**El software es el 90 % del trabajo**, y aproximadamente la mitad de ese software no existe
todavía en ningún proyecto abierto: el RTCP con IPMX Info Block, el traffic shaper en espacio
de usuario, e IS-11.

**Las dos decisiones que definen el proyecto:**
1. **x264/x265 antes que VideoToolbox** para la fase de conformidad, porque VideoToolbox no
   te deja controlar HRD ni insertar las SEI que TR-10-15 exige.
2. **Arrancar en `ts-refclk:localmac`**, aprovechando que IPMX permite explícitamente operar sin
   reloj común — que es justo lo que hace viable macOS, una plataforma sin timestamping
   hardware, como nodo IPMX.

---

## Fuentes

- [VSF Technical Recommendations](https://vsf.tv/technical-recommendations/) — índice de todas las TR-10
- [TR-10-1 System Timing and Definitions](https://static.vsf.tv/download/technical_recommendations/VSF_TR-10-1_2024-02-23.pdf)
- [TR-10-7 Compressed Video](https://static.vsf.tv/download/technical_recommendations/VSF_TR-10-7_2024-11-22.pdf)
- [TR-10-8 NMOS Requirements](https://static.vsf.tv/download/technical_recommendations/VSF_TR-10-8_2026-01-06.pdf)
- [TR-10-15 Part 2 — H.265](https://static.vsf.tv/download/technical_recommendations/VSF_TR-10-15-Part-2_2026-06-04.pdf)
- [TR-10-15 Part 3 — H.264](https://static.vsf.tv/download/technical_recommendations/VSF_TR-10-15-Part-3_2026-06-04.pdf)
- [BCP-006-02 NMOS With H.264](https://specs.amwa.tv/bcp-006-02) · [BCP-006-03 NMOS With H.265](https://specs.amwa.tv/bcp-006-03)
- [sony/nmos-cpp](https://github.com/sony/nmos-cpp) — implementación de referencia IS-04/IS-05 (compila en macOS)
