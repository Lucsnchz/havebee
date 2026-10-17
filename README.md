# Hive

Gestor de sesiones de IA para programar en macOS. Organiza todo en **Proyectos → Ramas → Sesiones** y cada sesión es una terminal real con Claude Code, Codex, Gemini, Grok o tu shell.

Qué cambió en la última ronda de mejoras, qué falta y cómo probarlo: [docs/MEJORAS.md](docs/MEJORAS.md).

## Instalar

```bash
scripts/build-app.sh --install   # compila y copia Hive.app a /Applications
```

Sin `--install` solo deja la app en `build/Hive.app`. Para instalar una versión nueva, primero cerrá Hive.

## Cómo se usa

- **Proyecto**: la carpeta de un repo git (⌘O o «Agregar proyecto», podés elegir varias). Al agregarlo se suma la rama actual; si elegís la carpeta de un worktree, se agrega el repo principal.
- **Rama**: una branch de git (⇧⌘N). Al crearla elegís dónde vive:
  - **Worktree**: carpeta propia, así varias sesiones trabajan en ramas distintas al mismo tiempo. Va **junto al proyecto** (`<repo>-<rama>`, sin `feature/` ni `fix/`; si Herd sirve la carpeta de arriba, queda en `https://<repo>-<rama>.test`) o en `<repo>.worktrees/<rama>`.
  - **Carpeta principal**: usa la carpeta del repo con `git switch`. Solo una rama activa a la vez; si abrís otra, Hive te pide confirmar y te avisa si hay cambios sin commitear o sesiones abiertas.
- **Sesión**: Claude Code, Codex, Gemini, Grok o Terminal, en la carpeta de su rama (⌘T, o clic derecho en una rama → «Nueva sesión…»). Si el agente no está instalado, Hive te dice cómo instalarlo en lugar de abrir una sesión que no arranca. Las de Claude y Codex se nombran solas con tu primer pedido.

El resumen muestra primero la carpeta principal y los worktrees, y después las ramas locales sin worktree y las remotas sin copia local. «Crear worktree…» abre la preparación con esa rama seleccionada y conserva sus commits y sesiones de Hive.

Un worktree nuevo copia los archivos locales ignorados (`.env`, `.mcp.json`, `auth.json`, permisos de Claude, `local.properties`, keystores, o lo que indique `.worktreeinclude`). En Laravel, «Dejar Laravel listo para usar» prepara las carpetas de storage, instala Composer, genera APP_KEY solo si falta, crea el enlace de storage e instala y compila los assets. Usa `.env.example` cuando no tiene `.env`. Conserva la conexión de base de datos y no ejecuta migraciones automáticamente.

Con Herd instalado registra un sitio propio, conserva la versión PHP y HTTPS del principal y ajusta APP_URL y los dominios de sesión. Los MCP del proyecto reciben rutas del worktree; los de PHP usan su versión de Herd. La primera sesión espera a que la preparación termine bien. Si falla, se conservan la rama y los archivos, con salida visible y «Reintentar», incluso después de reabrir Hive. Los scripts de `polyscope.json` o `conductor.json` tienen prioridad y se pueden revisar o editar antes de crear.

Al cerrar un worktree elegís conservar su carpeta o borrarla y, por separado, eliminar también la rama local. Hive muestra los commits pendientes de integrar en main y los archivos sin commit. Para borrar una rama o descartar cambios hay que escribir exactamente su nombre; main, master y la rama por defecto están protegidas. El estado se vuelve a comprobar antes del borrado. Las ramas remotas se conservan. Antes de borrar se ejecuta el script de cierre del proyecto, si hay; después se retira el alias de Herd creado por Hive si todavía apunta a ese worktree.

Los worktrees que ya existían (creados por Warp, Claude, a mano…) se detectan solos. Si quitás uno de Hive sin borrarlo, no vuelve a aparecer. Si borrás uno por fuera, desaparece solo de Hive, salvo que tenga algo corriendo: ahí avisa y se va cuando termina.

Sin nada elegido se ve el **Inicio**: las sesiones que necesitan permiso, las que te esperan, las que trabajan y las recientes. Sin proyectos, una bienvenida donde podés soltar carpetas.

## Dos vistas

Se cambia con el botón de la izquierda de la barra de herramientas o desde *Visualización → Vista*.

- **Árbol**: la barra lateral con Proyectos → Ramas → Sesiones.
- **Compacta**: una barra angosta con los íconos de los proyectos en grande y, arriba de todo, «Inicio». Al tocar un proyecto se abre en su última sesión activa. Arriba, las sesiones del proyecto como pestañas que aprovechan el ancho disponible para mostrar sus títulos, una pestaña «Resumen» con las ramas y un **+** para crear sesiones en la rama actual o en otra. Cuando hay muchas, podés desplazarte horizontalmente.

En las dos, los proyectos van en el mismo orden (el mismo de ⌃⌘1…⌃⌘9): arriba los fijados (clic derecho → «Fijar arriba») y un divisor fino; después los activos, que tienen algo prendido (un agente trabajando o esperándote, una Terminal con un proceso, un comando corriendo) o se usaron hoy (le escribiste a un agente o creaste una sesión: abrir un proyecto no cuenta, así no salta de lugar con el clic); después los apagados, atenuados; y al final «Terminales». Dentro de cada grupo manda el orden que elegís (arrastrando en el árbol o en el riel, o con «Subir» y «Bajar»), así un proyecto no salta de lugar por usarlo. Al cambiar el día, lo de ayer pasa solo a los apagados.

El ícono de cada proyecto tiene un solo aro, y es de estado: un arco que gira si alguna sesión está trabajando, naranja si alguna necesita permiso y verde si alguna terminó y te espera. Un globito dice cuántas sesiones te esperan; si alguna pide permiso es naranja y cuenta solo esas, con «!» delante (es igual en el árbol y en la vista compacta, y el detalle completo aparece al dejar el puntero encima).

La vista de cada rama muestra botones para crear sesiones, una tarjeta por sesión (estado, hace cuánto se usó y lo último que respondió la IA, o lo que pide si necesita permiso), los cambios, los últimos commits y las archivadas. En el encabezado, «Abrir sitio» y el menú del remoto. Si la rama está inactiva, a mitad de un rebase o sin carpeta, la vista lo dice y solo ofrece lo que se puede hacer.

## Más funciones

- **Buscador (⌘K o la lupa)**: escribí parte del nombre de un proyecto, rama, sesión o comando y abrilo con Enter. También encuentra las sesiones archivadas (al final): al elegir una ves su historial y la podés restaurar. Empezá con `>` para ver acciones: `>nueva claude` crea una sesión de Claude en la rama que elijas, y también hay «Nueva rama en…», «Agregar proyecto…», «Cambiar a vista compacta» y «Ajustes…». Empezá con `?` para buscar en lo que hablaste con Claude y Codex en todas las sesiones (también las archivadas): `?migración` y Enter abre la sesión con el historial en ese mensaje.
- **Responder desde el aviso**: cuando Claude o Codex terminan su turno, la notificación tiene «Responder». Lo que escribís va directo a la sesión, como si lo tipearas, y la sesión pasa a «Trabajando». Si la sesión no está corriendo (o si mientras tanto pasó a pedir permiso, para no aprobar nada sin querer), Hive la abre y deja tu respuesta en el portapapeles. Los avisos de permiso solo tienen «Abrir».
- **Terminales**: abajo de todo, un «proyecto» con terminales y agentes sueltos que arrancan en tu carpeta personal, fuera de cualquier repo.
- **La terminal**: ⌥ escribe ñ, tildes, @ y corchetes (se cambia en Ajustes), Shift+Enter hace salto de línea en los agentes, podés soltar o pegar archivos y capturas (se pega la ruta), ⌘clic en una ruta como `app/Models/Order.php:42` la abre en tu editor en esa línea (o la URL en el navegador), ⌘F busca y el clic derecho tiene Copiar, Pegar, Limpiar, enlaces y tamaño de letra.
- **La sesión**: arriba, el selector de IA para continuar la conversación con Claude o Codex y acciones con texto e ícono: Historial, Cambios, «Nueva sesión» (con la flechita elegís otro agente), Comandos, «Abrir sitio», el remoto, Buscar y «Acciones» (reiniciar, copiar o guardar el texto, abrir en otra app, detener, archivar). Abajo, una barra con la rama, ↑↓, los cambios y los comandos que corren.
- **Comandos por proyecto**: en el Resumen del proyecto guardás comandos como `npm run dev` o `php artisan serve`. Hive sugiere los del `package.json`, `artisan` (servidor, cola, `php artisan test` y `pail`), `composer.json`, `docker-compose` y Gradle (compilar, instalar en el teléfono, tests, lint y logcat de la app). Corren en la rama abierta: dentro de una sesión aparecen en la barra de abajo (un clic muestra su salida) y en el Resumen o la rama, en la esquina de abajo a la derecha. Desde ahí ves la salida, los detenés o los reiniciás.
- **Sitio y GitLab**: «Abrir sitio» abre la rama en el navegador (Herd o `polyscope.json`). El menú del remoto tiene «Traer cambios», «Publicar rama», «Crear MR en GitLab» (publica si hace falta y abre el MR), los MR de la rama y los pipelines (en GitHub, PR y Actions). Publicar y traer se cancelan con la ✕ junto al spinner.
- **Uso y límites**: cuánto contexto ocupa cada sesión de Claude y Codex (un anillito en la barra, «Conviene usar /compact» desde 80 %) y qué porcentaje usaste de los límites de 5 horas y semanal, al pie del sidebar y del riel. Un clic en esos indicadores abre «IAs y uso», con Claude, Codex, Gemini y Grok, su estado de instalación y los límites y reinicios disponibles. Gemini y Grok aparecen aunque Hive todavía no lea sus límites. Sin porcentajes queda un botón «IAs» para abrir el mismo panel.
- **Diff**: clic en un archivo de «Cambios» y ves qué cambió, con la lista de archivos al costado (↑/↓ para pasar de uno a otro). En un conflicto, «Usar la mía», «Usar la de ellos» y «Marcar resuelto» piden confirmación en la misma barra.
- **Archivar**: la ✕ de una pestaña (o ⌘W) archiva la sesión: deja de correr pero conserva su conversación. Las archivadas están al final de la vista de la rama, con «Restaurar» y «Ver historial», y también en el buscador.
- **Antes de cortar, pregunta**: ⌘W, ⌘R, ⌘. y ⌘Q piden confirmación si un agente está trabajando o esperando permiso, o si una Terminal tiene un proceso corriendo (`npm run dev`, un build).
- **Deshacer**: archivar, quitar un proyecto, borrar un comando o quitar un MCP muestran «Deshacer» unos segundos abajo, y también vale ⌘Z.

## Atajos

Todo Hive se maneja con el teclado. Los atajos están en los menús **Sesión** e **Ir** (y algunos en Edición y Visualización).

| Atajo | Qué hace |
|---|---|
| ⌘T | Nueva sesión del mismo agente que la abierta (o Claude) en la rama actual |
| ⇧⌘N | Nueva rama… |
| ⌘R | Reiniciar la sesión (o reanudarla si terminó); pregunta si está en algo |
| ⌘. | Detener la sesión (en una hoja, como el buscador, cancela); pregunta si está en algo |
| ⌘W | Archivar la sesión abierta (en Ajustes o en otra ventana, cierra); pregunta si está en algo |
| ⇧⌘W | Cerrar la ventana |
| ⌥⌘1 / ⌥⌘2 | Mostrar u ocultar el Historial / los Cambios |
| ⇧⌘H | Inicio |
| ⌘K | Buscar (con `>`, acciones; con `?`, en el historial de todas las sesiones) |
| ⌘J | Siguiente que te espera: primero la que pide permiso, después la que terminó hace más |
| ⌘1 … ⌘9 | Pestaña 1 a 9 del proyecto abierto |
| ⌃⌘1 … ⌃⌘9 | Proyecto 1 a 9, en el orden en que se ven (fijados, activos, apagados y «Terminales») |
| ⇧⌘] / ⇧⌘[ | Sesión siguiente / anterior (da la vuelta) |
| ⌥⌘↓ / ⌥⌘↑ | Proyecto siguiente / anterior, en el mismo orden (da la vuelta) |
| ⌘F, ⌘G, ⇧⌘G, ⌘E | Buscar en la terminal, siguiente, anterior y usar la selección |
| ⌥⌘K | Limpiar la terminal (en los agentes se usa `/clear`) |
| ⌘+ (o ⌘=), ⌘−, ⌘0 | Agrandar, achicar y volver al tamaño normal del texto de las terminales |
| ⌘O | Agregar proyecto |
| ⌘Z | Deshacer lo último (archivar, quitar un proyecto, borrar un comando o quitar un MCP) |

En la terminal: ⌥ más una letra compone ñ, tildes y @; ⌥←/⌥→ saltan de a palabras; Shift+Enter (o ⌥Enter) hace salto de línea en un agente; Esc frena el turno de un agente; ⌘clic abre la ruta o el enlace bajo el puntero.

Al saltar a una sesión con el teclado, el árbol se despliega hasta ella y la terminal toma el foco. En la vista compacta, el atajo de cada pestaña y de cada proyecto aparece al dejar el puntero encima; doble clic en una pestaña la renombra, y podés soltar carpetas en la barra de proyectos para agregarlas.

## Ajustes

*Hive → Ajustes* tiene tres pestañas:

- **General**: apariencia de toda la app (seguir al sistema, oscuro o claro), Claude y Codex en la terminal normal (para que la charla quede en el scroll), avisarle a la IA que existe el historial, mostrar el uso de Claude en su barra, y un aviso si tu `notify` de Codex tiene un formato que Hive no entiende.
- **Terminal**: fuente, tamaño (9 a 28 pt, también con ⌘+ y ⌘−), cursor, tema (seguir a la aplicación, oscuro o claro), qué hace la tecla ⌥ (escribir caracteres o funcionar como Meta) y con qué editor se abren los archivos (Android Studio y Xcode se eligen solos según el proyecto). La apariencia de la app y la terminal se aplican al instante y pueden elegirse por separado.
- **Avisos**: si macOS tiene los avisos permitidos (con un botón a Ajustes del Sistema si no) y si suenan.

## Historial que sobrevive a /clear

- **Cambiar de IA**: tocá el nombre de Claude o Codex en la barra y elegí «Continuar esta conversación con». Se conserva la misma pestaña, nombre e historial. Los mensajes anteriores se recuperan arriba en el scroll de esa misma terminal, también al reabrir Hive; cada respuesta conserva su autor y queda una marca del cambio. Hive detiene el agente anterior, guarda su conversación completa y abre la otra IA con un extracto reciente y acceso al historial completo; podés decirle «revisá el historial y seguí». Si el agente está trabajando, pregunta antes de cortarlo. El traspaso explícito comparte el contexto aunque el aviso general de historial esté desactivado y usa la terminal normal para mantener accesible el scroll. Por ahora está disponible entre Claude y Codex.
- **Si Codex falla al consultar la cuenta durante el arranque**: Hive reconoce el timeout de `account/read`, ofrece reintentar en el mismo chat y conserva el texto que Codex devuelve como «Unsent draft». El borrador sobrevive al reintento y al cierre de Hive; podés copiarlo o descartarlo. No se incorpora al historial ni se envía automáticamente.
- **Reanudar Codex**: los títulos y resúmenes automáticos no cambian el ID del chat ni aparecen como respuestas. Antes de abrirlo, Hive comprueba que su conversación existe; si una versión anterior guardó un ID temporal, recupera la última conversación nativa registrada en ese mismo chat. Si ya no existe ninguna, conserva el historial y abre Codex con ese contexto, sin enviar tareas automáticamente. Los registros auxiliares anteriores se limpian con una copia de respaldo.
- **En la terminal**: Claude y Codex corren en la terminal normal (no en su pantalla completa), así que después de `/clear` lo anterior sigue arriba en el scroll para leerlo y copiarlo. Al reanudar, Hive repone lo anterior al último cambio de IA o `/clear`, y el agente dibuja su conversación actual. Los borrados de arranque no eliminan el historial recuperado. Para los otros agentes, si borran pantalla y scroll justo después de un Enter, Hive manda lo que se veía al scroll con una línea divisoria. Cada terminal guarda 10.000 líneas; al recuperar una conversación, amplía la capacidad para incluir además el historial anterior.
- **Formato del historial recuperado**: tus mensajes aparecen con un borde azul y «Vos»; las respuestas, con el nombre de la IA y la hora. Títulos, negritas, listas, enlaces y bloques de código se dibujan con formato. Los adjuntos dicen «Imagen adjunta» y los prompts auxiliares de titulación no se muestran como parte de la charla. Los archivos originales se conservan completos.
- **Panel «Historial»** (botón del reloj en la sesión, ⌥⌘1): la conversación completa con Claude o Codex, también los mensajes intermedios de cada turno, con Markdown y bloques de código para copiar, separada por día y con «Todo» o «Solo respuestas finales». Marca cada `/clear` y cada corte (por ejemplo, «Se cortó: llegaste al límite de uso»). Hive guarda su propia copia de los transcripts, así que sigue ahí aunque el agente borre sus archivos. Tiene buscador, y el botón de los globitos busca lo mismo en todas las sesiones: abre ⌘K con `?` y lo que escribiste.
- **La IA también lo puede leer**: al arrancar, Hive le dice a Claude (`--append-system-prompt`) y a Codex (`developer_instructions`) dónde está el historial en Markdown y expone esa ruta en `HIVE_HISTORY_FILE`. Las instrucciones indican que «revisá el historial», «leé el historial» y «seguí» se refieren a ese archivo de la misma conversación.
- Se configura en *Hive → Ajustes*. Gemini no avisa sus mensajes, así que su panel no tiene la conversación: ofrece copiar el scroll de la terminal.

Los archivos están en `~/Library/Application Support/Hive/history/`. Lo de una sesión eliminada pasa a `history/deleted/` y se borra a los 30 días.

## MCP

En el Resumen de cada proyecto, la sección **MCP** muestra los servidores del `.mcp.json` del repo: agregar, editar (doble clic) o quitar. Claude lo lee directo; Hive se lo pasa también a **Codex** (`-c mcp_servers…`) y a **Gemini** (`GEMINI_CLI_SYSTEM_SETTINGS_PATH`) al abrir cada sesión. En un worktree que no tiene `.mcp.json`, Claude recibe el del repo con `--mcp-config`.

- **Sugeridos por stack** (en «Sugeridos»): Laravel (Boost, Herd, Nightwatch), Node (Playwright, Chrome DevTools), Next.js, Android/iOS, Xcode y Context7.
- **Globales**: los MCP que cada agente ya tiene configurados (Claude, Codex, Gemini), solo para verlos.
- Avisa si un MCP apunta a una ruta que no existe en tu Mac (por ejemplo, un `.mcp.json` armado en Windows).
- Si el `.mcp.json` tiene un error de sintaxis, Hive lo avisa y no lo toca (no se pierde ningún servidor). El editor guarda exactamente lo que cargó, y el entorno se escribe como `CLAVE=valor`, uno por línea.

## Personalizar y ordenar

- **Proyectos**: cada uno recibe un color distinto y, si el repo tiene logo (`apple-touch-icon`, favicon, ícono de Android, Xcode o `Resources/AppIcon.png` / `.icns`), lo usa como ícono. Clic derecho → «Personalizar…» para cambiar nombre, color e ícono (logo, iniciales, símbolo, emoji o una imagen tuya). El logo de Hive está disponible en [Resources/AppIcon.png](Resources/AppIcon.png) y aparece en ese selector; «Elegir imagen…» abre la carpeta del proyecto.
- **Ramas**: clic derecho → «Color». Si no tienen, usan el del proyecto.
- **Orden**: arrastrá ramas y sesiones en el sidebar, y proyectos en el árbol o en el riel (dentro de su grupo, ver «Dos vistas»), o usá «Subir / Bajar» en el menú contextual. «Fijar arriba» deja un proyecto siempre primero.
- El cursor de cada terminal toma el color de su proyecto.
- Panel de cambios estilo VS Code (botón ± en la barra de la sesión, ⌥⌘2): ícono por tipo de archivo, «Preparados» y «Sin preparar», doble clic abre el archivo.
- Claro u oscuro: en Ajustes → General elegís la apariencia de toda la aplicación, incluidas las barras, paneles y ventanas. En Ajustes → Terminal elegís si la terminal acompaña a la app o usa su propio tema.

Las sesiones siguen corriendo aunque cambies de sesión o cierres la ventana. Al salir de Hive se cortan, pero al volver a abrir cada sesión de agente **retoma su conversación** (`claude --resume` / `codex resume`) cuando la seleccionás.

Si Claude, Codex o Grok estaban trabajando, Hive guarda ese pendiente también durante la ejecución (para cubrir una caída). Al reabrir esa conversación, le pasa un único mensaje de continuación al proceso que la reanuda. Incluye los workflows y subagentes que seguían pendientes al terminar el turno principal; el mensaje pide revisar sus resultados y procesos antes de retomarlos. No abre todos los chats ni relanza comandos del proyecto.

Un turno terminado, un pedido de permiso/respuesta, Esc sin trabajo en segundo plano, Ctrl+C, Detener o Archivar cancelan la continuación automática. Antes de retomarla, Hive revisa los hooks que quedaron sin procesar y el final del transcript de Claude/Codex, para no repetir una tarea que terminó justo al cerrar. Hace falta recuperar la conversación nativa: sin ella no envía el mensaje. La reanudación queda marcada en el historial y respeta los permisos del agente. Las sesiones guardadas por versiones anteriores, sin un pendiente registrado, no se reactivan por el solo hecho de tener historial. Gemini sigue recuperando el chat sin enviar un prompt automático: Hive todavía no tiene señales confiables de fin y permisos para ese proveedor.

## Estados en el sidebar

| Indicador | Significado |
|---|---|
| arco miel que gira | El agente está trabajando |
| punto verde | Terminó su turno mientras no mirabas: te toca a vos |
| aro verde | Terminó y ya lo viste |
| «!» naranja | Necesita permiso o una respuesta |
| punto gris | Terminal abierta |
| ⏹ | El proceso terminó; «Reanudar conversación» lo vuelve a abrir |

Son los mismos íconos y colores en el sidebar, las pestañas, las tarjetas, el Inicio y el buscador. Las ramas y los proyectos muestran un resumen de sus sesiones, más archivos modificados (±) y commits ↑ sin pushear / ↓ sin traer. Cuando una sesión termina o pide permiso y no la estás mirando, llega una notificación de macOS; al hacerle clic, Hive abre esa sesión. El ícono del Dock muestra cuántas sesiones esperan. En una sesión de agente, Esc la saca de «Necesita permiso».

## Cómo sabe Hive qué hace cada agente

- **Claude Code**: se lanza con `--settings ~/Library/Application Support/Hive/claude-settings.json` (o `claude-settings-usage.json`, si está prendido el uso), que agrega hooks: `SessionStart`, `UserPromptSubmit`, `Notification` (leído según su tipo), `Stop`, `StopFailure` (el corte con su motivo), `PermissionRequest` (el pedido de permiso al instante) y `PreToolUse`, `PostToolUse` y `PostToolUseFailure`. Con el uso prendido suma un `statusLine` que guarda el contexto y los límites, y si ya tenías uno propio lo sigue mostrando. Tu configuración de Claude no se modifica.
- **Codex**: se lanza con `-c notify=[...]`. Si ya tenías un `notify` en `~/.codex/config.toml`, Hive lo sigue llamando igual (y Ajustes avisa si no entiende su formato). Los subagentes y los turnos internos que generan títulos o resúmenes se ignoran: no disparan «Tu turno», no reemplazan la respuesta ni cambian la conversación activa. El uso sale de su `token_count`.
- **Gemini**: no tiene hooks configurables desde afuera, así que su estado sale de la actividad de la terminal. Para reanudar, Hive busca el chat que Gemini guardó en `~/.gemini/tmp` (el que empezó más cerca del arranque) y usa `gemini --resume <id>`; si no lo encuentra, arranca una sesión nueva.
- **Grok** ([Grok Build](https://docs.x.ai/build/cli/reference), el CLI de xAI; se instala con `curl -fsSL https://x.ai/cli/install.sh | bash`): se lanza con `--session-id <id>` la primera vez y con `--resume <id>` cuando Grok ya guardó la sesión en `~/.grok/sessions`, y con `--no-alt-screen` para que la charla quede en el scroll. Grok no acepta hooks por parámetro, así que Hive instala los suyos en `~/.grok/hooks/hive.json` (`SessionStart`, `UserPromptSubmit`, las herramientas, `Notification`, `Stop`, `StopFailure` y `StopCancelled`). Llaman al puente solo dentro de Hive: afuera, `HIVE_EVENT_BIN` no existe y corren `true`.
- Claude, Codex y Grok avisan a través de `~/Library/Application Support/Hive/bin/hive-event`, que deja archivos en `events/` para que la app los lea.
- Como respaldo, si un agente marcado como «trabajando» deja de producir salida unos segundos, Hive lo pasa a «Tu turno».

## Datos

Todo vive en `~/Library/Application Support/Hive/` (`state.json` guarda proyectos, ramas y sesiones). Si `state.json` no se puede leer, Hive no lo pisa y te avisa; si está dañado, te dice dónde quedó la copia. Con la variable `HIVE_HOME` podés usar otra carpeta para hacer pruebas.

## Arquitectura

El paquete tiene tres módulos, con dependencias en un solo sentido (`Hive` → `HiveKit` → `HiveCore`):

| Módulo | Qué tiene | Depende de |
|---|---|---|
| **HiveCore** | Modelo, lógica pura e infraestructura sin UI. Compila en Swift 6 con concurrencia estricta. | Foundation, CryptoKit |
| **HiveKit** | `AppStore` (estado y coordinación), la terminal, los servicios del sistema y las vistas SwiftUI. También en Swift 6 estricto. | HiveCore, SwiftTerm |
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
  - `ProjectOrdering` ordena los proyectos (fijados, activos, apagados y «Terminales»).
  - `InterruptRule` decide cuándo preguntar antes de cortar una sesión, y `ConflictPrompt` arma la confirmación de un conflicto.
  - `BranchSituation` dice qué se puede hacer en una rama (worktree, principal, inactiva, a medias o sin carpeta).
  - `GitTimeouts` elige cuánto puede tardar cada llamada a git.
  - `SessionTitle` arma el nombre automático y `HistoryExport` arma la línea de tiempo del historial.
  - `WorktreeIncludes`, `HerdSites`, `EnvFile`, `ProjectScripts`, `SiteURL` y `RemoteHost` preparan los worktrees y los enlaces a Herd y a GitLab.
  - `ClearPreserver` es el filtro de `/clear`.
  - `ProjectTree` agrupa las consultas y los cambios sobre el árbol de proyectos.
- **Los efectos van detrás de protocolos inyectados** (`AppEnvironment`): `GitClient` (git real o falso), `CommandRunning`, `ProcessStarting`, `SessionNotifying`, el reloj y el calendario, la carpeta de datos (`HivePaths`) y la de cada agente (`AgentStorage`). En la app se usa `AppEnvironment.live()`; en los tests, carpetas temporales y versiones falsas.
- **Nada bloquea el hilo principal:** git, el lanzamiento de las sesiones y las lecturas de disco corren en segundo plano. `ProcessCommandRunner` espera con un semáforo (no con `waitUntilExit`, que gira el run loop y provoca reentrada), manda stdout y stderr a archivos para que nada se trabe, corta lo que se pasa de su límite de tiempo con todo su grupo de procesos y se puede cancelar a pedido (`CancellableWork`).
- **JSON tipado** (`JSONValue`, `Sendable`) en lugar de `[String: Any]`.
- `AppStore.init` solo carga el estado; los servicios en segundo plano arrancan con `start()`.

## Tests

```bash
scripts/test.sh                              # todo
scripts/test.sh HiveCoreTests                # solo el core (unos 3 s)
scripts/test.sh StoreProjectOrder            # cualquier filtro
scripts/test.sh --snapshots /tmp/capturas    # además guarda capturas de cada vista, en claro y en oscuro
```

- **HiveCoreTests** (Swift Testing, en paralelo): el modelo y la migración de estados viejos; el árbol de proyectos y su orden; los parsers de git (status v2, renombres, conflictos); git real sobre repos temporales (worktrees, checkout, diffs, ramas remotas, límites de tiempo); la preparación de ramas (archivos a copiar, Herd, `.env`, scripts); los eventos de cada agente; la regla del silencio; los comandos de lanzamiento; MCP (lectura, escritura, archivos rotos, editor); el historial, los transcripts y la búsqueda; el uso y los límites; el estado guardado; el puente de eventos ejecutando el script de verdad; las conversaciones previas de cada agente; el teclado de la terminal, los enlaces y las rutas para pegar; el filtro de `/clear`; el buscador; las sugerencias; los logos; los procesos y las rutas.
- **HiveKitTests**:
  - el `AppStore` completo con git real, carpetas temporales y avisos y procesos falsos: proyectos, ramas, checkout, sesiones, eventos, avisos, archivar, quitar y deshacer, confirmaciones, orden y fijados, comandos, remotos, MCP y persistencia
  - la terminal con procesos reales (teclado, soltar y pegar, enlaces, menú, procesos en primer plano)
  - los menús y atajos, y el contraste de los colores en claro y en oscuro
  - cada pantalla y hoja dibujada en una ventana fuera de pantalla, en claro y en oscuro

Ningún test lee tu estado real ni usa `UserDefaults.standard`. Más detalle en [docs/MEJORAS.md](docs/MEJORAS.md#5-cómo-probarlo).

## Código

SwiftUI + [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), compilado con Swift Package Manager.

Los logos de los agentes son SVG dentro del código (`HiveKit/Views/LogoAssets.swift`), así funcionan igual en la app, en `swift run` y en los tests. Son marcas de sus dueños: Claude, de la extensión oficial de Claude Code para VS Code; Codex, de [LobeHub Icons](https://github.com/lobehub/lobe-icons) (sin el fondo blanco y con los arcos reescritos para que CoreSVG los dibuje bien); Gemini, de [Dashboard Icons](https://github.com/homarr-labs/dashboard-icons); Grok, de LobeHub Icons (es de un solo color: se dibuja en el color del texto, así se ve en claro y en oscuro).

Para probar la app sin tocar tu estado real: `HIVE_HOME=<carpeta> swift run Hive`.

