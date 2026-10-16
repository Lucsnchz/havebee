# Hive

Gestor de sesiones de IA para programar en macOS. Organiza todo en **Proyectos → Ramas → Sesiones** y cada sesión es una terminal real con Claude Code, Codex o tu shell.

## Instalar

```bash
scripts/build-app.sh --install   # compila y copia Hive.app a /Applications
```

Sin `--install` solo deja la app en `build/Hive.app`. Para instalar una versión nueva, primero cerrá Hive.

## Cómo se usa

- **Proyecto**: la carpeta de un repo git (⌘O o «Agregar proyecto»). Al agregarlo se suma la rama actual.
- **Rama**: una branch de git. Al crearla elegís dónde vive:
  - **Worktree**: carpeta propia en `<proyecto>.worktrees/<rama>`, junto al repo. Varias sesiones pueden trabajar en ramas distintas al mismo tiempo.
  - **Carpeta principal**: usa la carpeta del repo con `git checkout`. Solo una rama activa a la vez; si abrís otra, Hive te pide confirmar el checkout y te avisa si hay cambios sin commitear o sesiones abiertas.
- **Sesión**: Claude Code, Codex, Gemini o Terminal, en la carpeta de su rama. Clic derecho en una rama → «Nueva sesión…».

Los worktrees que ya existían (creados por Warp, Claude, a mano…) se detectan solos. Si quitás uno de Hive sin borrarlo, no vuelve a aparecer.

## Dos vistas

Se cambia con el botón de la izquierda de la barra de herramientas o desde *Visualización → Vista*.

- **Árbol**: la barra lateral con Proyectos → Ramas → Sesiones.
- **Compacta**: una barra angosta con los íconos de los proyectos en grande y, arriba de todo, «Inicio». Al tocar un proyecto se abre en su última sesión activa. Arriba, las sesiones del proyecto como pestañas, una pestaña «Resumen» con las ramas y un **+** para crear sesiones en la rama actual o en otra.

En las dos, el ícono de cada proyecto tiene un borde de estado: un arco que gira si alguna sesión está trabajando, verde si alguna terminó y te espera, naranja si alguna necesita permiso. En la vista compacta, además, un globito con cuántas sesiones te esperan.

La vista de cada rama muestra botones para crear sesiones, una tarjeta por sesión (estado, hace cuánto se usó y lo último que respondió la IA), los cambios y los últimos commits.

## Más funciones

- **Buscador (⌘K o la lupa)**: escribí parte del nombre de un proyecto, rama, sesión o comando y abrilo con Enter. También encuentra las sesiones archivadas (al final): al elegir una ves su historial y la podés restaurar. Empezá con `>` para ver acciones: `>nueva claude` crea una sesión de Claude en la rama que elijas, y también hay «Nueva rama en…», «Agregar proyecto…», «Cambiar a vista compacta» y «Ajustes…». Empezá con `?` para buscar en lo que hablaste con Claude y Codex en todas las sesiones (también las archivadas): `?migración` y Enter abre la sesión con el historial en ese mensaje.
- **Responder desde el aviso**: cuando Claude o Codex terminan su turno, la notificación tiene «Responder». Lo que escribís va directo a la sesión, como si lo tipearas, y la sesión pasa a «Trabajando». Si la sesión no está corriendo (o si mientras tanto pasó a pedir permiso, para no aprobar nada sin querer), Hive la abre y deja tu respuesta en el portapapeles. Los avisos de permiso solo tienen «Abrir».
- **Terminales**: abajo de todo, un «proyecto» con terminales y agentes sueltos que arrancan en tu carpeta personal, fuera de cualquier repo.
- **Comandos por proyecto**: en el Resumen del proyecto guardás comandos como `npm run dev` o `php artisan serve` (Hive sugiere los del `package.json`, `artisan`, `composer.json` y `docker-compose`). Corren en la rama abierta y aparecen en la esquina de abajo a la derecha, donde ves su salida, los detenés (Ctrl+C) o los reiniciás.
- **Diff**: clic en un archivo de «Cambios» y ves qué cambió, con la lista de archivos al costado (↑/↓ para pasar de uno a otro).
- **Archivar**: la ✕ de una pestaña (o ⌘W) archiva la sesión: deja de correr pero conserva su conversación. Las archivadas están al final de la vista de la rama, con «Restaurar», y también en el buscador.

## Atajos

Todo Hive se maneja con el teclado. Los atajos están en los menús **Sesión** e **Ir** (y algunos en Edición y Visualización).

| Atajo | Qué hace |
|---|---|
| ⌘T | Nueva sesión del mismo agente que la abierta (o Claude) en la rama actual |
| ⇧⌘N | Nueva rama… |
| ⌘R | Reiniciar la sesión (o reanudarla si terminó) |
| ⌘. | Detener la sesión (en una hoja, como el buscador, cancela) |
| ⌘W | Archivar la sesión abierta (en Ajustes o en otra ventana, cierra) |
| ⇧⌘W | Cerrar la ventana |
| ⌥⌘1 / ⌥⌘2 | Mostrar u ocultar el Historial / los Cambios |
| ⇧⌘H | Inicio |
| ⌘K | Buscar (con `>`, acciones; con `?`, en el historial de todas las sesiones) |
| ⌘J | Siguiente que te espera: primero la que pide permiso, después la que terminó hace más |
| ⌘1 … ⌘9 | Pestaña 1 a 9 del proyecto abierto |
| ⌃⌘1 … ⌃⌘9 | Proyecto 1 a 9 |
| ⇧⌘] / ⇧⌘[ | Sesión siguiente / anterior (da la vuelta) |
| ⌥⌘↓ / ⌥⌘↑ | Proyecto siguiente / anterior |
| ⌘F, ⌘G, ⇧⌘G, ⌘E | Buscar en la terminal, siguiente, anterior y usar la selección |
| ⌥⌘K | Limpiar la terminal (en los agentes se usa `/clear`) |
| ⌘+ (o ⌘=), ⌘−, ⌘0 | Agrandar, achicar y volver al tamaño normal del texto de las terminales |
| ⌘O | Agregar proyecto |

Al saltar a una sesión con el teclado, el árbol se despliega hasta ella. En la vista compacta, el atajo de cada pestaña y de cada proyecto aparece al dejar el puntero encima; doble clic en una pestaña la renombra, y podés soltar carpetas en la barra de proyectos para agregarlas.

## Historial que sobrevive a /clear

- **En la terminal**: Claude corre en la terminal normal (no en su pantalla completa), así que después de `/clear` lo anterior sigue arriba en el scroll para leerlo y copiarlo. Para los otros agentes, si borran pantalla y scroll justo después de un Enter, Hive manda lo que se veía al scroll con una línea divisoria. Cada terminal guarda 10.000 líneas.
- **Panel «Historial»** (botón del reloj en la sesión): todo lo que hablaste con Claude o Codex, con buscador y botón para copiar, marcando cada `/clear` y cada corte (por ejemplo, «Se cortó: llegaste al límite de uso»). El botón de los globitos busca lo mismo en todas las sesiones: abre ⌘K con `?` y lo que escribiste.
- **La IA también lo puede leer**: al arrancar, Hive le dice a Claude (`--append-system-prompt`) y a Codex (`developer_instructions`) dónde está el historial en Markdown. Lo consultan solo si mencionás algo que ya no está en su contexto.
- Se configura en *Hive → Ajustes*. Gemini no avisa sus mensajes, así que no tiene panel de historial (sí el scroll).

Los archivos están en `~/Library/Application Support/Hive/history/`.

## MCP

En el Resumen de cada proyecto, la sección **MCP** muestra los servidores del `.mcp.json` del repo: agregar, editar (doble clic) o quitar. Claude lo lee directo; Hive se lo pasa también a **Codex** (`-c mcp_servers…`) y a **Gemini** (`GEMINI_CLI_SYSTEM_SETTINGS_PATH`) al abrir cada sesión. En un worktree que no tiene `.mcp.json`, Claude recibe el del repo con `--mcp-config`.

- **Sugeridos por stack**: Laravel (Boost, Herd, Nightwatch), Node (Playwright, Chrome DevTools), Next.js, Android/iOS, Xcode y Context7.
- **Globales**: los MCP que cada agente ya tiene configurados (Claude, Codex, Gemini), solo para verlos.
- Avisa si un MCP apunta a una ruta que no existe en tu Mac (por ejemplo, un `.mcp.json` armado en Windows).

## Personalizar y ordenar

- **Proyectos**: cada uno recibe un color distinto y, si el repo tiene logo (`apple-touch-icon`, favicon, ícono de Android o Xcode), lo usa como ícono. Clic derecho → «Personalizar…» para cambiar nombre, color e ícono (logo, iniciales, símbolo, emoji o una imagen tuya).
- **Ramas**: clic derecho → «Color». Si no tienen, usan el del proyecto.
- **Orden**: arrastrá proyectos, ramas y sesiones en el sidebar, o usá «Subir / Bajar» en el menú contextual.
- El cursor de cada terminal toma el color de su proyecto.
- Panel de cambios estilo VS Code (botón de la derecha en la barra): ícono por tipo de archivo, preparados y sin preparar, doble clic abre el archivo.

Las sesiones siguen corriendo aunque cambies de sesión o cierres la ventana. Al salir de Hive se cortan, pero al volver a abrir cada sesión de agente **retoma su conversación** (`claude --resume` / `codex resume`) cuando la seleccionás.

## Estados en el sidebar

| Indicador | Significado |
|---|---|
| spinner | El agente está trabajando |
| punto verde | Terminó su turno mientras no mirabas: te toca a vos |
| aro verde | Terminó y ya lo viste |
| ⚠︎ naranja | Necesita permiso o una respuesta |
| punto gris | Terminal abierta |
| ⏹ | El proceso terminó; «Reanudar conversación» lo vuelve a abrir |

Las ramas y los proyectos muestran un resumen de sus sesiones, más archivos modificados y commits ↑ sin pushear / ↓ sin traer. Cuando una sesión termina o pide permiso y no la estás mirando, llega una notificación de macOS; al hacerle clic, Hive abre esa sesión. El ícono del Dock muestra cuántas sesiones esperan.

## Cómo sabe Hive qué hace cada agente

- **Claude Code**: se lanza con `--settings ~/Library/Application Support/Hive/claude-settings.json`, que agrega hooks (`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Notification`, `Stop`). Tu configuración de Claude no se modifica.
- **Codex**: se lanza con `-c notify=[...]`. Si ya tenías un `notify` en `~/.codex/config.toml`, Hive lo sigue llamando igual.
- **Gemini**: no tiene hooks configurables desde afuera, así que su estado sale de la actividad de la terminal. Para reanudar, Hive busca el chat que Gemini guardó en `~/.gemini/tmp` y usa `gemini --resume <id>`; si no lo encuentra, arranca una sesión nueva.
- Los dos avisan a través de `~/Library/Application Support/Hive/bin/hive-event`, que deja archivos en `events/` para que la app los lea.
- Como respaldo, si un agente marcado como «trabajando» deja de producir salida unos segundos, Hive lo pasa a «Tu turno».

## Datos

Todo vive en `~/Library/Application Support/Hive/` (`state.json` guarda proyectos, ramas y sesiones). Con la variable `HIVE_HOME` podés usar otra carpeta para hacer pruebas.

## Arquitectura

El paquete tiene tres módulos, con dependencias en un solo sentido (`Hive` → `HiveKit` → `HiveCore`):

| Módulo | Qué tiene | Depende de |
|---|---|---|
| **HiveCore** | Modelo, lógica pura e infraestructura sin UI. Compila en Swift 6 con concurrencia estricta. | Foundation, CryptoKit |
| **HiveKit** | `AppStore` (estado y coordinación), la terminal, los servicios del sistema y las vistas SwiftUI. | HiveCore, SwiftTerm |
| **Hive** | Solo el punto de entrada (`HiveApplication.main()`). | HiveKit |

Principios:

- **Las decisiones son funciones puras en HiveCore**, el store solo las aplica:
  - `AgentEventInterpreter` decide qué hacer con cada evento de un agente.
  - `SilenceRule` decide cuándo un agente dejó de trabajar.
  - `LaunchPlanner` arma el comando y el entorno de cada sesión.
  - `WorktreeSync` agrega los worktrees creados por fuera.
  - `BranchPlanner` prepara las ramas.
  - `SwitcherIndex` resuelve el buscador (resultados, acciones y qué resaltar).
  - `SessionNavigation` y `ProjectTabs` deciden a dónde llevan los atajos (pestañas, sesión vecina, siguiente que te espera).
  - `ClearPreserver` es el filtro de `/clear`.
  - `ProjectTree` agrupa las consultas y los cambios sobre el árbol de proyectos.
- **Los efectos van detrás de protocolos inyectados** (`AppEnvironment`): `GitClient` (git real o falso), `CommandRunning`, `ProcessStarting`, `SessionNotifying`, el reloj, la carpeta de datos (`HivePaths`) y la de cada agente (`AgentStorage`). En la app se usa `AppEnvironment.live()`; en los tests, carpetas temporales y versiones falsas.
- **Nada bloquea el hilo principal:** git corre en tareas en segundo plano, y `ProcessCommandRunner` espera con un semáforo (no con `waitUntilExit`, que gira el run loop y provoca reentrada) y manda stderr a un archivo para que el pipe nunca se llene.
- **JSON tipado** (`JSONValue`, `Sendable`) en lugar de `[String: Any]`.
- `AppStore.init` solo carga el estado; los servicios en segundo plano arrancan con `start()`.

## Tests

```bash
scripts/test.sh                              # todo (~200 tests, unos 15 s)
scripts/test.sh HiveCoreTests                # solo el core (~1 s)
scripts/test.sh --snapshots /tmp/capturas    # además guarda capturas de cada vista
```

- **HiveCoreTests** (Swift Testing, en paralelo): el modelo y la migración de estados viejos; el árbol de proyectos; los parsers de git; git real sobre repos temporales (worktrees, checkout, diffs); la preparación de ramas; los eventos de cada agente; la regla del silencio; los comandos de lanzamiento; MCP (lectura, escritura, Codex, Gemini, globales, catálogo); el historial; el estado guardado; el puente de eventos ejecutando el script de verdad; las conversaciones previas de cada agente; el filtro de `/clear`; el buscador; las sugerencias; los logos; los procesos y las rutas.
- **HiveKitTests**:
  - el `AppStore` completo con git real, carpetas temporales y avisos y procesos falsos: proyectos, ramas, checkout, sesiones, eventos, avisos, archivar, quitar, orden, comandos, MCP y persistencia
  - la terminal con procesos reales
  - cada pantalla y hoja dibujada en una ventana fuera de pantalla

## Código

SwiftUI + [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), compilado con Swift Package Manager.

Los logos de los agentes son SVG dentro del código (`HiveKit/Views/LogoAssets.swift`), así funcionan igual en la app, en `swift run` y en los tests. Son marcas de sus dueños: Claude, de la extensión oficial de Claude Code para VS Code; Codex, de [LobeHub Icons](https://github.com/lobehub/lobe-icons) (sin el fondo blanco y con los arcos reescritos para que CoreSVG los dibuje bien); Gemini, de [Dashboard Icons](https://github.com/homarr-labs/dashboard-icons).

Para probar la app sin tocar tu estado real: `HIVE_HOME=<carpeta> swift run Hive`.

