# IPMX — bucle RTP con RTCP e IPMX Info Block

Captura de pantalla o **ingesta HDMI/SDI** → x264/x265 → RFC 6184/7798 → UDP multicast →
VideoToolbox → ventana.

**H.264 y H.265 conviven**: `--codec h264|h265` en ambos binarios. IPMX exige los dos, y poder
hacer A/B entre ellos es lo que hace falta para la Fase 1.

Fases 0 a 3 hechas: bucle cerrado, bitstream conforme, **RTCP Sender Reports con el IPMX
Info Block** y traffic shaping CINST/CMAX. Sin NMOS y sin PTP todavía.

El plan completo y la justificación normativa están en
[IPMX-macOS-encoder-decoder.md](IPMX-macOS-encoder-decoder.md). Los PDF de VSF fijados
están en [specs/](specs/).

---

## Requisitos

- macOS 26+ (probado en macOS 26.5, Apple Silicon). El código en sí solo necesita macOS 14;
  el suelo lo impone la libx264 de Homebrew, cuya bottle se compila con deployment target 26.
  Para bajarlo hay que compilar x264 desde fuente con `-mmacosx-version-min=14.0` y ajustar
  `platforms:` en [Package.swift](Package.swift).
- Swift 6. Para **compilar y ejecutar** bastan las Command Line Tools; para `swift test`
  hace falta **Xcode completo**, porque XCTest y swift-testing se distribuyen con Xcode y no
  con las CLT. Si `swift test` falla con `no such module 'XCTest'`, comprueba a dónde apunta
  el toolchain:

  ```bash
  xcode-select -p
  ```

  Si responde `/Library/Developer/CommandLineTools`, cámbialo con
  `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.
- `brew install x264 x265 pkg-config`
- Permiso de **Screen Recording** para la aplicación de terminal desde la que lances el
  encoder: System Settings → Privacy & Security → Screen Recording. macOS atribuye el
  permiso al terminal, no al binario; tras concederlo hay que reiniciar el terminal.

## Compilar

```bash
swift build -c release
```

## Elegir la fuente

```bash
swift run ipmx-encoder --list-devices                       # qué hay conectado y en qué formatos
swift run ipmx-encoder --source screen                      # captura de pantalla (por defecto)
swift run ipmx-encoder --source capture --device magewell   # ingesta HDMI/SDI
```

`--device` acepta índice, un trozo del nombre o el unique id. Sin él, se elige el primer
dispositivo **externo**, y solo si no hay ninguno se cae a la cámara integrada.

Magewell es **UVC class compliant**, así que no necesita SDK: aparece como `AVCaptureDevice`
de tipo `.external` y toda la integración es AVFoundation estándar. Blackmagic DeckLink y AJA
necesitan sus propios SDK en C++ y serían un archivo hermano de
[CaptureDeviceSource.swift](Sources/ipmx-encoder/CaptureDeviceSource.swift), no un cambio en él.

Requiere permiso de **Camera** (System Settings → Privacy & Security → Camera), atribuido a la
aplicación de terminal igual que el de Screen Recording. El diálogo solo aparece si lanzas el
binario desde un terminal interactivo.

### Las dos fuentes no son intercambiables

La diferencia es normativa, no de fontanería:

| | `screen` | `capture` |
|---|---|---|
| Naturaleza | sintética | conversión de baseband |
| `a=mediaclk` | `direct=0` | **`sender`** (TR-10-1 §10.5, Async Media) |
| Cadencia | temporizador que **tira** del último buffer | el dispositivo **empuja**, el temporizador solo vigila |
| Timestamp RTP | aritmética exacta sobre el índice de frame | derivado del instante real de llegada |
| Formato de píxel | NV12 nativo, cero conversión | 4:2:2 habitual → NV12 con `VTPixelTransferSession` |

Lo de la cadencia importa: con una capturadora, el reloj de la tarjeta es la autoridad. Un
temporizador local haría que dos relojes libres derivaran y acabarías repitiendo o tirando un
frame periódicamente sin motivo. Por eso el temporizador se degrada a vigilante y solo actúa si
la señal desaparece — que es lo que mantiene viva la cadencia de Sender Reports que exige
TR-10-15 §15.

Verificado en vivo contra un `AVCaptureDevice` a 1080p30: el Info Block dice `mediaclk=sender`,
`measuredpixclk` sale 62208000 = 1920×1080×30, y el delta de RTP entre Sender Reports es
3001/2999/3001 ticks en vez de los 3000 nominales — sigue el reloj del dispositivo, que es lo
que `sender` declara, frente a los +1500 exactos e invariables de la fuente de pantalla.

Sin verificar todavía: la conversión 4:2:2 → 4:2:0. Los dispositivos probados entregan NV12
nativo y la negociación toma el camino de cero conversiones, así que
[PixelFormatConverter.swift](Sources/ipmx-encoder/PixelFormatConverter.swift) solo se ejercitará
con una capturadora que presente UYVY o v210.

**No conformidad conocida con `--source capture`**: una capturadora es conversión de baseband,
así que TR-10-1 §10.2 exige reportar el pixel clock **medido** y el raster total real, con
150 ppm de tolerancia. UVC entrega frames, no intervalos de blanking, así que seguimos usando
los valores de TR-10-9 §10. El encoder lo avisa al arrancar. Cerrarlo requiere un SDK de
dispositivo que exponga la temporización de señal — que es lo principal que compra un DeckLink
o un AJA frente a una Magewell.

## Probar sin red

Todo en un solo Mac, sobre loopback, sin switch ni multicast:

```bash
./scripts/run-local-loop.sh          # H.264
./scripts/run-local-loop.sh h265     # H.265
```

O a mano, en dos terminales:

```bash
swift run ipmx-encoder --codec h265 --dest 127.0.0.1 --iface 127.0.0.1 --sdp sdp/h265.sdp
```

```bash
swift run ipmx-decoder --sdp sdp/h265.sdp --iface 127.0.0.1
```

El decoder saca el códec, el destino, el puerto y los parameter sets del propio SDP, así que
`--codec` en el receptor solo hace falta si no le pasas `--sdp`.

El encoder escribe `sdp/stream.sdp` en cuanto tiene SPS/PPS; el decoder puede leer de ahí el
destino, el puerto y los parameter sets, que es lo que le entregaría una conexión IS-05 real.

## Probar en multicast

```bash
swift run ipmx-encoder --dest 239.10.10.10 --port 50000
swift run ipmx-decoder --group 239.10.10.10 --port 50000
```

Sin `--iface`, ambos eligen la primera interfaz IPv4 no-loopback activa. En un Mac con Wi-Fi
más un adaptador Thunderbolt querrás fijarla a mano. El switch necesita IGMP snooping **con
querier**; sin querier el tráfico se inunda o desaparece a los pocos minutos.

## Traffic shaping CINST/CMAX

El encoder activa por defecto el modelo de compatibilidad de red de TR-10-7 §10. Los
datagramas RTP entran en una cola fija y un hilo dedicado con
`THREAD_TIME_CONSTRAINT_POLICY` los libera mediante un token bucket:

- capacidad = `CMAX = MAX(16, INT(MaxRate/21600))`
- recarga = `MaxRate` paquetes por segundo
- los primeros CMAX paquetes pueden salir como una ráfaga; después se espacian a MaxRate
- esperas largas con `mach_wait_until`, últimos 50 µs con busy-wait

Por defecto MaxRate se estima conservadoramente desde `--bitrate` y `--mtu`, suponiendo como
mínimo un 75 % de ocupación media y reservando además cuatro paquetes auxiliares por frame
para NAL parciales, parameter sets y SEI. Para una prueba de conformidad hay que sustituir esa
estimación por el máximo medido:

```bash
swift run ipmx-encoder --bitrate 8000 --max-packet-rate 1200
```

`--no-shaping` conserva el envío en ráfaga para depuración, pero deja el stream fuera de
TR-10-7 §10. El Sender Report usa los contadores que ya salieron a la red, no los que siguen
esperando en la cola.

### Qué pasa si MaxRate se queda corto

La admisión es **no bloqueante y por access unit completo**. Si la cola no tiene sitio para el
frame entero, se descarta entero y se cuenta; nunca se emite un frame a medias ni se consumen
números de secuencia de paquetes que no van a salir.

Esto es deliberado y es la parte que más importa: el productor es el hilo de la cadencia, que es
también quien emite los Sender Reports. Bloquearlo pararía la cadencia de RTCP que TR-10-15 §15
exige constante — y lo haría en silencio. Perder un frame bajo sobrecarga se recupera; perder la
cadencia de reports, no.

Las estadísticas periódicas muestran la señal útil:

```
1200 frames, 1200 reports, 8186 queued, 9222.3 ms in queue, 563 dropped AU
```

**`ms in queue`** es el indicador de sobrecarga: crece sin límite cuando MaxRate está por debajo
de lo que produce el encoder. Y el log dice la causa y el remedio en cuanto se descarta el primer
access unit.

### Validación con captura externa

La captura debe hacerse en otro equipo conectado a un puerto SPAN/TAP; medir en el mismo Mac
no valida el jitter de salida de su NIC. En el observador Linux:

```bash
sudo tcpdump -i enp1s0 -s 0 -B 8192 -w ipmx-phase3.pcap \
  'udp dst port 50000'
python3 scripts/validate-traffic-shape.py ipmx-phase3.pcap \
  --port 50000 --max-packet-rate 1200
```

El script es un segundo validador independiente del scheduler Swift: lee el PCAP clásico,
reconstruye el token bucket y devuelve código 1 ante una infracción. Para la aceptación formal,
abrir el mismo PCAP en **EBU LIST** y ejecutar el análisis ST 2110-21 Network Compatibility
Model con el CMAX que imprime el encoder. EBU LIST sigue siendo la autoridad de laboratorio;
el script permite automatizar la regresión local. La página pública actual de
[EBU LIST](https://tech.ebu.ch/list) declara ST 2110-21 y ST 2110-22 con JPEG XS, pero no
enumera H.264/H.265; si la versión instalada no clasifica el payload comprimido, conservar el
resultado del validador y contrastar con EBU qué perfil/plugin usar para la aceptación.

## Verificar

```bash
swift test
```

El target usa **los dos frameworks a la vez**, con un reparto deliberado:

- **swift-testing** (`import Testing`) para todo el comportamiento: 130 tests en 20 suites.
  Los casos parametrizados con `@Test(arguments:)` son la razón principal — casi todo se
  ejecuta **contra los dos códecs** a partir de la misma tabla (`arguments: VideoCodec.allCases`),
  igual que los atributos que exigen las TR y los tamaños de NAL alrededor del umbral de
  fragmentación. Cada fallo se reporta con su argumento concreto.
- **XCTest** para las medidas de rendimiento en
  [ThroughputTests.swift](Tests/IPMXCoreTests/ThroughputTests.swift). swift-testing todavía
  no tiene API de medición, así que `measure` sigue siendo la única forma de fijar líneas
  base y detectar regresiones.

Para ejecutar solo una parte:

```bash
swift test --filter "RFC 6184"
```

Cifras medidas en un M4 Pro, que son las que importan para la Fase 3: paquetizar un keyframe
de 1080p de 200 KB cuesta **~80 µs**, en torno al 0.5 % de un intervalo de frame a 60 fps.
El hilo real-time que hará el shaping CINST/CMAX tiene margen de sobra.

---

## Estructura

```
Package.swift
Sources/
  CX264/  CX265/            módulos de sistema para libx264 y libx265
    module.modulemap
    shim.h                  envuelve los macros *_encoder_open versionados y los arrays de las
                            structs de picture
  IPMXCore/                 todo lo que comparten los dos extremos y los dos códecs
    VideoCodec.swift        h264 | h265, y el tamaño de cabecera NAL del que cuelga todo
    NALUnit.swift           tipos de NAL de ambos códecs, Annex B, conversión a AVCC/HVCC
    RTPPacket.swift         cabecera RTP fija (RFC 3550 §5.1)
    VideoPacketizer.swift   RFC 6184 FU-A y RFC 7798 FU, sin agregación
    VideoDepacketizer.swift reensamblado, detección de huecos, STAP-A/AP en ingesta
    RTPStreamSender.swift   sella timestamps y marker bit, empuja al socket
    UDPSocket.swift         emisión/recepción UDP, membresía multicast, selección de interfaz
    MediaClock.swift        reloj de 90 kHz de marcha libre (ts-refclk:localmac)
    SDP.swift               fmtp por códec, profile_tier_level, des-escapado de RBSP
    MediaPort.swift         reglas de puerto de TR-10-7 §7, shall contra should
    MediaClockRelationship.swift  direct=0 contra sender, TR-10-1 §10.5
    Bitstream.swift         lector/escritor de bits, Exp-Golomb, escapado de RBSP
    HEVCVideoParameterSet.swift  lee y reescribe el vps_timing_info que x265 no emite
    TrafficShaper.swift    token bucket CINST/CMAX e hilo Mach real-time
    IPMXInfoBlock.swift     bloque 0x5831 y los Media Info Blocks 0x0005 / 0x0009 / 0x000A
    RTCPSenderReport.swift  Sender Report con el timestamp truncado de PTP, y su parser
    RTCPStreamSender.swift  emisión en media+1 y el contador de block version
    CommandLineOptions.swift
  ipmx-encoder/
    main.swift
    ScreenSource.swift        captura ScreenCaptureKit en NV12
    VideoEncoder.swift        protocolo común y configuración
    X264Encoder.swift         libx264, NV12 directo
    X265Encoder.swift         libx265, requiere I420 planar
    ChromaDeinterleaver.swift NV12 -> I420 con vImage, solo para x265
    FrameCadence.swift        cadencia: modo tirar (pantalla) o empujar (capturadora)
    VideoSource.swift         la fuente y lo que su naturaleza implica normativamente
    CaptureDeviceSource.swift ingesta HDMI/SDI por AVFoundation, sin SDK
    PixelFormatConverter.swift 4:2:2 -> 4:2:0 con VTPixelTransferSession
  ipmx-decoder/
    main.swift
    VideoToolboxDecoder.swift H.264 y HEVC
    PlayerWindow.swift        AVSampleBufferDisplayLayer
Tests/IPMXCoreTests/
  TestNALUnits.swift        constructores de NAL sintéticos para ambos códecs
  PacketizationTests.swift  swift-testing: cabeceras NAL, Annex B, FU, round trip, pérdidas
  RTPHeaderTests.swift      swift-testing: cabecera RTP y reloj de 90 kHz
  SDPTests.swift            swift-testing: SDP por códec, RBSP, direccionamiento, flags
  BitstreamTests.swift      swift-testing: bits, Exp-Golomb, RBSP, reescritura del VPS
  RTCPTests.swift           swift-testing: Info Block, Media Info Blocks, Sender Report
  MediaClockTests.swift     swift-testing: direct=0 contra sender, en SDP y en RTCP
  ThroughputTests.swift     XCTest: medidas de rendimiento, ambos códecs
scripts/
  net-tuning.sh             sysctl de buffers UDP
  run-local-loop.sh
  inspect-bitstream.py      valida el bitstream contra TR-10-15, ambos códecs
  validate-traffic-shape.py valida un PCAP externo contra MaxRate/CMAX
  rtcp-monitor.py           decodifica Sender Reports en vivo, y escribe pcap
  ipmx-rtcp.lua             disector de Wireshark para el Info Block
sdp/                        generado por el encoder
```

---

## Qué ya cumple la norma, y qué no

Ya alineado con las TR, porque cambiarlo después sale caro:

- Reloj RTP de **90 kHz** y timestamp compartido por todos los paquetes de un frame (TR-10-7 §9)
- **Un solo VCL NAL por paquete UDP** (TR-10-15 §9) — nunca se agrega con STAP-A
- Puerto UDP **par y > 1024 forzado** en ambos binarios: TR-10-7 §7 lo dice como *shall*, así
  que un puerto impar aborta con error en vez de avisar. Importa por una razón concreta: RTCP va
  al puerto inmediatamente superior (TR-10-1 §8.7), así que un puerto de media impar pondría el
  RTCP en un par y colisionaría con la media del siguiente stream. El > 5000 es un *should* y
  solo avisa
- Random access point cada ≤ 5 s, con el flag limitado a ese máximo (TR-10-15 §11)
- **Decode order = output order**, sin B-frames (TR-10-15 §10)
- Perfil **High** (H.264) forzado de verdad: los presets rápidos de x264 apagan CABAC y el
  transform 8x8, y `x264_param_apply_profile` solo restringe, nunca eleva, así que
  `--preset ultrafast` produce en silencio Constrained Baseline — que TR-10-15 Part 3 §12 no admite
- Perfil **Main** 8 bits 4:2:0 (H.265), el mínimo de TR-10-15 Part 2 §12
- **PACI descartado** en ingesta: TR-10-15 Part 2 §9 prohíbe emitirlo
- `nuh_layer_id` y `nuh_temporal_id_plus1` preservados al fragmentar y reconstruir (RFC 7798)
- El `profile_tier_level` del SPS de H.265 se lee **tras des-escapar el RBSP**: cae justo donde
  los encoders insertan emulation prevention bytes, e indexar en crudo da un perfil plausible
  pero equivocado
- VUI con colorimetría BT.709 y rango limitado, coherente con el `RANGE=NARROW` del SDP
- SDP con `TP=2110TPW`, `ts-refclk:localmac`, `mediaclk` según la fuente, y **`b=AS` derivado
  del MaxRate del shaper**: TR-10-7 §11 exige que incluya el paquete IP completo, así que al
  bitrate codificado se le suman las cabeceras IP/UDP/RTP a MaxRate. Con 8000 kbps y 1193 pps
  salen 8382, no 8000
- **Traffic shaping CINST/CMAX** con token bucket, cola acotada e hilo Mach real-time. Si el
  sistema rechaza `THREAD_TIME_CONSTRAINT_POLICY`, el encoder lo declara como best-effort en
  vez de afirmar conformidad silenciosamente
- **RTCP Sender Report por frame** en el puerto de media más uno (TR-10-1 §8.7), con el IPMX
  Info Block `0x5831` y los Media Info Blocks `0x0005` (vídeo) más `0x000A`/`0x0009` (códec).
  El campo llamado *NTP timestamp* lleva el formato truncado de PTP —segundos y **nanosegundos**,
  no una fracción de 2³²— que es donde una implementación que siga RFC 3550 al pie de la letra
  se equivoca en silencio
- **Cadencia constante** aunque la pantalla esté quieta (TR-10-15 §15). La captura deposita en
  un hueco y un temporizador tira de él, así que un escritorio inmóvil reencoda el último buffer
  en vez de parar el stream. Sin esto no se puede cumplir «si el encoder salta un frame, no
  puede saltarse su Sender Report»
- `htotal`, `vtotal` y `measuredpixclk` según **TR-10-9 §10**, que es la regla para un sender
  cuya salida no viene de convertir una señal baseband: no hay blanking que medir. Van tanto en
  el `a=fmtp` del SDP (TR-10-1 §10.2) como en el Media Info Block, y **salen del mismo objeto**:
  `SDPDescription` guarda el propio `VideoMediaInfoBlock` en vez de una copia de sus valores,
  porque TR-10-15 §16 exige que la línea `fmtp` y el Media Info Block usen la misma sintaxis y
  dos fuentes de verdad separadas acaban divergiendo
- **HRD Type II activo por defecto** en H.264: `nal_hrd_parameters_present_flag = 1`,
  `cpb_cnt_minus1 = 0`, Buffering Period SEI en cada punto de acceso aleatorio y Picture Timing
  SEI en cada access unit (TR-10-15 §10). TR-10-7 §10 desactiva el Virtual Receiver Buffer Model
  de ST 2110 para vídeo comprimido y deja el buffering al códec, así que el HRD es el **único**
  contrato de temporización que le queda a un receptor IPMX. Coste medido a 1080p60/8 Mbit/s:
  6.2 kbps de SEI, un 0.08 %. Se puede desactivar con `--no-hrd`, pero entonces el stream no
  es conforme

Deliberadamente fuera de esta fase:

| Falta | Fase | Nota |
|---|---|---|
| NMOS IS-04 / IS-05 / IS-11 | 4 | `sony/nmos-cpp` cubre IS-04 e IS-05; IS-11 es propio |
| PTP | — | Innecesario mientras se opere en `ts-refclk:localmac` |
| Buffer de recepción y reordenado | 4 | Ahora se asume entrega en orden en una LAN tranquila |
| Main10 (H.265 10 bits) | — | La ruta vImage pasaría a 16 bits. Main 8 bits es el mínimo de TR-10-15 Part 2 §12 |

---

## Ver el RTCP

Dos herramientas, deliberadamente independientes del código Swift: si validas un serializador
con su propio parser, un malentendido compartido pasa desapercibido.

```bash
python3 scripts/rtcp-monitor.py --group 127.0.0.1 --port 50001 --count 3
```

Decodifica los Sender Reports contra las tablas de las TR, comprueba la regla de TR-10-9 §10,
avisa si el campo NTP no lleva nanosegundos, y mide la cadencia real. Con `--pcap fichero.pcap`
guarda lo que recibe.

Para Wireshark, [scripts/ipmx-rtcp.lua](scripts/ipmx-rtcp.lua) disecciona el Info Block entero.
Sin él, Wireshark muestra `Sender Report (PSE:Unknown)`; con él, cada campo:

```bash
cp scripts/ipmx-rtcp.lua ~/.config/wireshark/plugins/
tshark -r captura.pcap -X lua_script:scripts/ipmx-rtcp.lua -V
```

Se registra como heurístico de UDP, así que no hace falta «Decode As» ni fijar un puerto.

## Validar el bitstream

La Fase 1 se comprueba, no se supone. El encoder puede volcar el elementary stream y
[scripts/inspect-bitstream.py](scripts/inspect-bitstream.py) lo contrasta contra
TR-10-15 Part 3:

```bash
swift run ipmx-encoder --dump /tmp/out.264 --fps 60 --dest 127.0.0.1 --iface 127.0.0.1
python3 scripts/inspect-bitstream.py /tmp/out.264 --fps 60
```

Cubre **los dos códecs** y detecta cuál es por la extensión, por el `rtpmap` del SDP o por la
estructura de los NAL. Es un parser real con lector Exp-Golomb y des-escapado de RBSP, porque
el VUI y el `hrd_parameters` no están alineados a byte — y en H.265 el VUI está **detrás de
`st_ref_pic_set()`**, que hay que recorrer entero aunque no se compruebe nada de él.

Comprueba perfil, colorimetría, HRD, SEI, intervalo entre puntos de acceso aleatorio y slices
por imagen. Devuelve exit code 1 si falla algún «shall», así que entra en CI tal cual. También
acepta un `.sdp` directamente (en ese modo no puede comprobar SEI ni acceso aleatorio).

Estado actual: **los dos códecs pasan entero.**

### El VPS de H.265 se reescribe

TR-10-15 Part 2 §10 exige `vps_timing_info_present_flag = 1` con `vps_num_units_in_tick` y
`vps_time_scale` puestos, y **x265 no tiene ninguna API pública de VPS timing** — solo los
equivalentes de VUI. Así que [HEVCVideoParameterSet.swift](Sources/IPMXCore/HEVCVideoParameterSet.swift)
parchea el VPS a la salida del encoder, antes de paquetizarlo.

No se puede hacer con un splice de bytes: los campos caen a 66 bits del final de una sintaxis
no alineada, detrás de `profile_tier_level` y de los bucles de capas, así que hay que
reconstruir el RBSP entero con el bit writer de [Bitstream.swift](Sources/IPMXCore/Bitstream.swift)
y volver a insertar los emulation prevention bytes. El VPS pasa de 24 a 34 bytes, una vez por
punto de acceso aleatorio.

Se aplica a **todos** los VPS, no solo al primero: `bRepeatHeaders` pone uno delante de cada
IRAP, y la copia parcheada es la que llega tanto al stream RTP como al `sprop-vps` del SDP.
Si el `vps_extension_flag` estuviera puesto, el parcheo se abstiene en vez de arriesgarse a
corromper el VPS. Verificado que VideoToolbox acepta el VPS reescrito sin perder un frame.
