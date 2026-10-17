# Mejoras de Hive · octubre 2026

Qué se hizo en esta ronda, qué falta y cómo probarlo. Cubre todo lo que hay desde el commit `405d9ae` hasta la punta de la rama `ultra/integration`: más de 200 commits, sin push. Los tests pasaron de unos 200 a **862**, y la app compila con cero warnings.

Para el uso diario está la [guía en español](README.es.md). Este archivo es el registro de la ronda.

---

## 1. Resumen: qué cambia en el día a día

- **Ves enseguida qué te espera.** El Inicio agrupa las sesiones en «Necesitan permiso», «Tu turno», «Trabajando» y «Recientes». ⌘J te lleva a la próxima, empezando por la que pide permiso. A Claude y a Codex les contestás desde la notificación, sin abrir Hive.
- **La terminal anda como iTerm para quien escribe en español.** ⌥ escribe ñ, tildes y @, y Shift+Enter hace salto de línea en los agentes. Podés soltar o pegar archivos y capturas, ⌘clic en `app/Models/Order.php:42` abre el editor en esa línea y ⌘F busca.
- **Un worktree nuevo arranca listo para Herd.** Se crea junto al proyecto, así Herd lo sirve como `https://<carpeta>.test`, con el `.env` copiado y su `APP_URL`, `auth.json` y los permisos de Claude, y «Preparar» corre composer y npm. «Abrir sitio», «Publicar rama» y «Crear MR en GitLab» quedan a un clic.
- **El historial es la conversación completa.** Queda guardado en Hive (sobrevive a `/clear` y a que Claude borre sus archivos), se ve con Markdown y se busca en todas las sesiones con ⌘K y `?`. Además ves cuánto te queda del límite de Claude y de Codex.
- **Un reflejo ya no corta nada.** ⌘W, ⌘R, ⌘. y ⌘Q preguntan antes si un agente está trabajando o esperando permiso, o si una Terminal tiene algo corriendo. Los conflictos piden confirmación. Archivar, quitar un proyecto, borrar un comando y quitar un MCP se deshacen con ⌘Z.
- **Los proyectos no saltan de lugar.** En el riel y en el árbol van primero los fijados, después lo activo de hoy, después lo apagado (atenuado) y al final «Terminales». Dentro de cada grupo manda tu orden. Hay un solo aro de estado y un solo globito, iguales en todos lados.
- **Grok es un agente más.** Sesiones de Grok Build (el CLI de xAI) con su logo, su estado (trabajando, permiso, tu turno) y la conversación que se retoma al reabrir.
- **Un workflow no te avisa antes de tiempo.** Si Claude termina su turno pero deja subagentes o un workflow trabajando, la sesión sigue en «En segundo plano…», sin aviso ni globito, y te avisa recién cuando Claude retoma y termina de verdad.
- **Se ve bien en claro y en oscuro.** Hay un solo acento miel, el contraste está medido con tests, y el verde y el naranja quedan solo para el estado de las sesiones.
- **Menos sustos.** git no pisa ni pierde estado. Un `.mcp.json` roto no se reescribe y un `state.json` ilegible no se pisa. Los worktrees borrados por fuera se van solos y Hive ya no se cae con datos raros de uso.

### Cómo se trabajó

| Parte | Qué se hizo |
|---|---|
| **1** | Siete paquetes en paralelo, cada uno con su revisión: núcleo del store, agentes e historial, git/worktrees/Herd, terminal y sesión, proyectos/MCP/stack, navegación y teclado, y sistema de diseño. Después vino la integración (I1 a I9) y una verificación con tres lentes (completitud, UX visual y correctitud), que dejó 28 hallazgos. |
| **2** | Las correcciones de esos hallazgos en cuatro carriles: flujos, visual, historial y el riel nuevo. Después, integración, otra verificación (correctitud y UX) y un pulido final. |

---

## 2. Qué se hizo, por área

Todo lo de esta sección está en el código y en `git log 405d9ae..HEAD`.

### Diseño

- **Un solo acento miel que se adapta.** El texto en acento es más oscuro en claro (#8F5F00), para que se lea. Los rellenos (botón principal, pasos de la Bienvenida, selección de ⌘K, chips elegidos, burbuja del historial, selección del diff) usan miel #E8A92A con texto negro, así ya no se ven marrones.
- **Cada color tiene su significado:**
  - verde y naranja, solo para las sesiones (te espera / necesita permiso);
  - azul para comandos corriendo y avisos neutros;
  - rojo adaptado a cada modo para errores, detener, conflictos y carpeta faltante;
  - el uso alto va en miel, y en rojo desde 95 %.

  Un test recorre el código de las vistas para que no vuelvan los colores del sistema.
- **Contraste medido.** El gris de los datos (rutas, fechas, autor, «en main») llega a 4,5:1 sobre el fondo y sobre las tarjetas. En claro, los colores de git son los de VS Code Light+ y los íconos de archivo se oscurecen.
- **Cada estado se dibuja de una sola forma** en el Inicio, ⌘K, las tarjetas, el sidebar, las pestañas, el riel y la barra de la sesión:
  - «!» naranja: necesita permiso;
  - punto verde: te espera y no lo viste;
  - aro verde hueco: tu turno, ya visto;
  - arco miel que gira: trabajando;
  - punto gris: abierta, sin actividad;
  - ⏹: terminó.

  Ya no hay animaciones a 30 fps, y con «Reducir movimiento» el arco queda quieto.
- **El Resumen del proyecto** va en el orden Ramas → Comandos → MCP, con un solo «Agregar» por sección y la ruta para copiar.
- **La vista de rama** muestra primero las sesiones, con cuatro píldoras de «Nueva sesión». Después vienen «Cambios · N», los últimos commits (también de una rama inactiva) y las archivadas con «Ver historial».
- **La tarjeta de sesión** muestra «⏱ 2:14» al pie, sin repetir «Trabajando». Si el agente pide permiso, aparece el pedido en naranja.
- **La barra de la sesión** ya no tiene cápsulas vacías: «Abrir sitio», el remoto y el uso aparecen solo si hay algo que mostrar.
- **«Cambios»** tiene un solo nombre y un solo ícono (±), con los grupos «Preparados» y «Sin preparar».
- **Los textos** van en primera persona («No pude…», «No encuentro Gemini»), con voseo y comillas «». Hay menos jerga («Sin rama remota», «Merge a medias») y la Bienvenida dice «Te damos la bienvenida a Hive».
- **Los logos** siguen siendo los originales: `LogoAssets.swift` no se tocó.

### Usabilidad

- **Inicio y Bienvenida.** Sin nada elegido se ve el Inicio, y sin proyectos, una Bienvenida con tres pasos y una zona para soltar carpetas. Arriba del sidebar y del riel hay una fila «Inicio».
- **Deshacer.** Aparece una cápsula abajo durante 6 s, y también funciona ⌘Z. Sirve para:
  - archivar;
  - quitar un proyecto (vuelve con sus ramas, sesiones dormidas, archivadas, comandos, color e ícono);
  - borrar un comando;
  - quitar un MCP.

  Los avisos cortos usan la misma cápsula, por ejemplo «Copié .env, auth.json y 2 más a «feature/x»».
- **Antes de cortar, pregunta** (una sola regla, `InterruptRule`):
  - ⌘W, la X de la pestaña, ⌘R y ⌘. preguntan si hay un agente trabajando o esperando permiso, o una Terminal con un proceso en primer plano (Hive lo detecta igual que Terminal.app);
  - la pregunta sugiere Esc o Ctrl+C para cortar solo el turno o el proceso;
  - ⌘Q también cuenta las sesiones esperando permiso, los procesos en terminales y los comandos.
- **Agentes no instalados.** ⌘T, el menú Sesión, ⌘K, el botón «Nueva sesión» y la primera sesión de una rama nueva ya no abren un agente que no está: muestran «Gemini no está instalado» con el comando y el botón «Copiar comando». En los menús figura «(no instalado)».
- **Diálogos honestos.**
  - Hay una cola de alertas y el rojo queda solo para lo que borra.
  - Quitar dice qué se detiene («Se detienen 2 comandos y 1 sesión») y que no se borra nada del disco.
  - Eliminar una sesión dice qué se borra y si estaba en algo.
- **Agregar proyectos.**
  - ⌘O deja elegir varias carpetas.
  - La carpeta de un worktree agrega el repo principal.
  - Un repo con HEAD desacoplado ya no crea una rama «HEAD».
- **Si la carpeta principal cambia de rama por fuera de Hive**, avisa y ofrece «Mover las sesiones ahí».
- **Nombre automático.** Una sesión de Claude o de Codex toma el nombre de tu primer pedido, sin palabras colgadas al final («Agregá validación de stock»). Si la renombraste a mano, no se toca.
- **Lanzar no traba la app.** Mientras arranca se ve «Abriendo Claude Code…».
- **Foco.** Elegir una sesión le da el foco a su terminal: un clic, ⌘K, ⌘J, ⌘1…⌘9, el Inicio, un aviso o ⏎ en el sidebar.
- **La hoja «Nueva rama» se renovó:**
  - el foco arranca en el nombre, los espacios pasan a guiones y el nombre se valida mientras escribís;
  - muestra la carpeta que se va a crear;
  - «Desde» separa ramas locales y remotas, con `origin/main` preelegida y el fetch en segundo plano;
  - si el repo no tiene commits, ofrece «Crear primer commit»;
  - tiene un selector «Worktree | Carpeta principal»;
  - el interruptor de copiar se apaga si no hay nada para copiar;
  - incluye «Preparar al crear» y chips para la primera sesión;
  - recuerda el modo y la primera sesión que elegiste.
- **La vista de rama se adapta a la situación** (`BranchSituation`): worktree, carpeta principal, inactiva, rebase o merge a medias, o sin carpeta.
  - Sin carpeta, la única acción es «Quitar de Hive…», más los comandos que siguen corriendo, para poder detenerlos.
  - Con un rebase a medias no ofrece sesiones nuevas.

### Terminal

- **⌥ escribe** ñ, tildes, @, `[ ] { } | \ ~` (ajuste «Tecla ⌥ Option»). ⌥← y ⌥→ saltan de a palabras, ⌥⌫ borra una palabra y ⌥Espacio es un espacio común.
- **Shift+Enter y ⌥Enter** hacen salto de línea en los agentes, sin enviar y sin disparar el filtro de `/clear`.
- **Soltar y pegar.** Los archivos se pegan con la ruta escapada. Una imagen sin archivo se guarda como PNG temporal y se pega la ruta. ⌘V con una imagen en un agente se la pasa al agente.
- **⌘clic** en rutas (`ruta:línea:columna`, relativas, `~/`, las `a/` y `b/` de los diffs) y en URLs:
  - los archivos se abren en tu editor, en esa línea (VS Code, Cursor, Zed o PhpStorm; Android Studio o Xcode según el proyecto);
  - las carpetas, en Finder.
- **Menú contextual en español:** Copiar, Pegar, Seleccionar todo, Buscar…, Limpiar, Abrir o Copiar enlace, Mostrar carpeta en Finder, y Agrandar y Achicar.
- **Apariencia en vivo:** fuente, tamaño, cursor, tema claro (con paleta legible) u oscuro, y tecla ⌥. También ⌘+, ⌘− y ⌘0.
- **Barras de la sesión.**
  - Arriba, la barra de herramientas tiene: Historial y Cambios, Nueva sesión (con la flechita elegís otro agente), Comandos, Abrir sitio, el remoto, el uso, la lupa y «Más» (Reiniciar, Copiar todo, Guardar como .txt, Abrir en, Detener y Archivar).
  - Abajo, una barra con la rama, ↑↓ y los cambios, más chips de los comandos que muestran su salida en un popover.

  La esquinita de comandos ya no tapa la terminal.
- **Si falta el agente**, la sesión muestra «No encuentro Gemini», con «Copiar comando de instalación» y «Reintentar».
- **Detener corta también los shells que ignoran SIGTERM**: manda SIGTERM, después SIGHUP y, al final, SIGKILL.
- **Seguridad:** un programa ya no puede leer tu portapapeles por la terminal (OSC 52).
- **La campana** hace rebotar el Dock si no estás mirando.
- Claude sigue con `CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1`, y Codex corre en la terminal normal con `tui.alternate_screen="never"`.

### Agentes e historial

- **Grok (Grok Build, de xAI).** Se crea como cualquier agente (⌘T, el menú, ⌘K, las tarjetas) y, si no está instalado, Hive muestra `curl -fsSL https://x.ai/cli/install.sh | bash`.
  - Arranca con `--session-id <id>` y, cuando Grok ya guardó la sesión en `~/.grok/sessions`, se retoma con `--resume <id>`. Va con `--no-alt-screen`, así la charla queda en el scroll.
  - Grok no acepta hooks por parámetro: Hive instala `~/.grok/hooks/hive.json`, que llama al puente solo dentro de Hive (afuera corre `true`). Se lee el payload en camelCase o snake_case.
  - Estados como en Claude: el prompt pone «Trabajando», las herramientas lo confirman, `Stop` te deja el turno con su respuesta (o el aviso de siempre), `StopFailure` dice el motivo («xAI está saturado: reintentá»), `StopCancelled` no avisa, y los subagentes o un workflow en segundo plano mantienen la sesión trabajando.
  - El logo es el original (LobeHub Icons), de un solo color: se dibuja con el color del texto.
- **Estados más precisos con Claude:**
  - los `Notification` se leen según su tipo, así los avisos de computer use, push o cuota ya no dan un «Tu turno» falso;
  - `PermissionRequest` marca «Necesita permiso» al instante, con «Pide permiso para Bash: npm test» o «…para editar app/Models/User.php»;
  - un plan dice «Tiene un plan listo para que lo apruebes» y una pregunta, «Te hace una pregunta: …»;
  - Esc saca a un agente de «Necesita permiso» o de «Trabajando».
- **Cortes con motivo.** Un `StopFailure` dice por qué se cortó: «Llegaste al límite de uso», «Anthropic está saturado», «/login»… En el historial queda «⚠︎ Se cortó: llegaste al límite de uso», con el código chiquito aparte.
- **Subagentes, workflows y segundo plano.** El `Stop` de Claude trae `background_tasks`, con el tipo de cada tarea:
  - con subagentes o un workflow andando, la sesión sigue trabajando («En segundo plano…» en la tarjeta y en la barra), sin aviso ni globito, aunque la terminal quede quieta: no aplican la regla del silencio ni el aviso de inactividad de Claude, y Esc no la saca;
  - cuando terminan, Claude retoma solo, y su `Stop` sin tareas te deja el turno con el aviso de siempre;
  - si lo que queda es un shell o un monitor (un `php artisan serve`, por ejemplo), te toca y avisa «Terminó; queda 1 tarea en segundo plano», porque puede no terminar nunca;
  - de respaldo, si en 15 minutos no llega ningún evento de la sesión ni de sus subagentes, pasa a «Tu turno» y avisa.
  
  Antes, la sesión figuraba «Tu turno» mientras el workflow trabajaba y, al entrar, parecía volver sola a «Trabajando».
- **Avisos automáticos.** Los mensajes que inyecta Claude (tareas en segundo plano, `/loop`, recordatorios) van como «Aviso automático» y no cuentan como mensaje tuyo.
- **Codex:**
  - ignora los subagentes y los threads de VS Code;
  - elige su thread por la fecha de creación;
  - busca el rollout en la carpeta de su día;
  - lee tu `notify` con un parser TOML chico, y Ajustes avisa si no lo entiende.
- **Gemini:** retoma el chat que empezó más cerca del arranque, y si había uno guardado, ese.
- **Android:** si existe el SDK, se define `ANDROID_HOME` y se suma `platform-tools` al PATH.
- **Historial completo.** Hive guarda su propia copia desde los transcripts de Claude y de Codex. El panel tiene:
  - Markdown y bloques de código con su botón Copiar;
  - separadores por día;
  - «Todo» o «Solo respuestas finales»;
  - búsqueda con «3 de 12»;
  - el copiar de cada mensaje al pasar el mouse y en el menú contextual;
  - en Gemini y en Terminal, «Copiar el scroll de la terminal».
- **Una sola búsqueda global: ⌘K con `?`.**
  - Incluye las archivadas, no distingue tildes ni mayúsculas y muestra hasta 200 resultados sin marcas de Markdown.
  - El botón del panel abre ⌘K con `?` y lo que ya escribiste.
  - Restaurar una archivada abre el historial en ese mensaje.
- **Lo eliminado** va a `history/deleted/` y se borra a los 30 días.
- **Uso y límites.** Para Claude, Hive usa un statusLine propio, encadenado al tuyo si tenés uno. Para Codex, lee su `token_count`. Se ve así:
  - un anillito de contexto en la barra («72%»: gris hasta 80 %, después miel con «Conviene usar /compact» y rojo desde 95 %);
  - barritas al pie del sidebar y del riel;
  - «La semanal se reinicia el dom 21:11».

### Git, worktrees, Herd y GitLab

- **Límites de tiempo según la operación** (`GitTimeouts`): 20 s para lo local, 2 min para la red y para borrar un worktree, y 30 min para lo que corre hooks o LFS (push, pull, switch, worktree add y commit). Un git colgado vuelve con error en lugar de trabar.
- **«Publicar rama» y «Traer cambios»:**
  - se cancelan con la X junto al spinner;
  - su estado vive en el store, así no se pierde al cambiar de sesión, y hay una sola operación por rama;
  - quitar la rama o el proyecto los corta.
- **El estado de git se lee mejor:** renombres, rutas con comillas, «Remota borrada», ↑↓, la operación a medias (rebase, merge, cherry-pick, revert o bisect) y la rama correcta durante un rebase.
- **Diff y conflictos.**
  - La hoja muestra renombres y conflictos, se puede agrandar y tiene «Copiar diff».
  - «Usar la mía», «Usar la de ellos» y «Marcar resuelto» confirman en la misma barra, con el nombre del archivo y lo que se pierde. En un rebase, los lados se invierten bien.
  - «Marcar resuelto» relee el archivo y pregunta solo si quedan marcadores. Esc cancela.
- **Ramas:**
  - el checkout usa `git switch`;
  - una rama remota se crea con `--track`, y partir de una base remota usa `--no-track`;
  - funciona con dos remotos.
- **Worktrees:**
  - uno bloqueado se puede borrar con «Borrar igual»;
  - un `git checkout -b` dentro de un worktree renombra la rama en Hive;
  - quitar uno cuya carpeta falta toca solo esa entrada;
  - los borrados por fuera se van solos (ver «Robustez»).
- **Listos para Herd:**
  - si Herd sirve la carpeta padre, el worktree va al lado (`<repo>-<rama>`, sin `feature/`, `fix/` ni `chore/`); si no, va en `<repo>.worktrees/<rama>`;
  - se copian `.env`, `.env.*`, `auth.json`, `.claude/settings.local.json`, `local.properties` y los keystores (o lo que diga `.worktreeinclude`), solo si git los ignora y sin pisar nada;
  - se reescriben `APP_URL`, `SESSION_DOMAIN` y `SANCTUM_STATEFUL_DOMAINS`.
- **«Preparar al crear»:**
  - toma el script de `polyscope.json` o de `conductor.json`, o lo propone según el stack (`composer install && npm install && npm run build`, pnpm, yarn o bun según el lockfile), y suma `herd secure` si el principal tiene certificado;
  - corre en la esquinita como «Preparar <rama>», con `HIVE_ROOT_PATH`, `HIVE_WORKTREE_PATH`, `HIVE_BRANCH` y `HIVE_FOLDER`;
  - al borrar el worktree, antes corre el script de cierre («Cerrar <rama>»).
- **«Abrir sitio»** toma la URL de `polyscope.json` o de Herd (solo http o https) y deja abrirla o copiarla.
- **El menú del remoto** tiene «Traer cambios» (`pull --ff-only`), «Publicar rama», «Crear MR en GitLab» (publica si hace falta y abre el MR contra la rama por defecto), «Ver MRs de la rama» y «Ver pipelines». En GitHub ofrece PR y Actions.
- **La revisión de git:**
  - no tiene carreras;
  - corre hasta 4 en paralelo;
  - en segundo plano revisa cada 60 s, solo las carpetas con trabajo;
  - al abrir Hive, el estado carga sin esperar a git.

### MCP y stack

- **Un `.mcp.json` con errores ya no se reescribe**, tampoco con claves sin comillas o con comillas simples. Aparece el aviso «.mcp.json tiene un error de sintaxis» con «Abrir», y «Agregar» queda deshabilitado.
- **El editor guarda exactamente lo que cargó:** sse, headers, campos desconocidos, args con comillas y el entorno sin cambiar `--` por una raya. El entorno se edita a la vista («CLAVE=valor»), acepta URLs con variables de entorno y avisa si el nombre se repite o la URL no sirve.
- Ya no lee el disco al dibujar, y vuelve a leer al volver a Hive.
- **Los sugeridos** van en chips dentro de «Sugeridos (N)», y cada fila dice «local» o «remoto».
- **Comandos sugeridos:**
  - Android: «Compilar debug», «Instalar en el teléfono», «Tests», «Lint» y «Logcat de la app», con el applicationId real y los sabores;
  - Laravel suma «Tests» (`php artisan test`) y, si tenés pail, «Logs» (`php artisan pail`).
- **Personalizar proyecto:** acepta emojis de verdad (banderas, familias) y descarta las letras. Los logos se buscan sin trabar la app.

### Navegación y atajos

- **Menús «Sesión» e «Ir»** con todos los atajos (tabla en la sección 3). Un test verifica que no se repitan ni choquen con los de macOS, y los atajos responden aunque no hayas abierto el menú.
- **⌘K:**
  - resultados con encabezados por tipo, coincidencias resaltadas y el mismo ícono de estado;
  - acciones con `>`;
  - las archivadas muestran su historial en la misma hoja, con «Restaurar» y «Volver»;
  - historial con `?`;
  - proyectos en el orden del riel;
  - un agente no instalado aparece como «No instalado · <comando>».
- **Responder desde la notificación.**
  - Los avisos de turno tienen «Responder», y los de permiso, «Abrir».
  - Si la sesión no corre, o mientras tanto pasó a pedir permiso, Hive la abre y deja tu respuesta en el portapapeles, así no aprueba nada sin querer.
  - El sonido se configura.
- **Vista compacta:**
  - el Inicio va en el riel;
  - las pestañas son accesibles, con la rama truncada al medio y doble clic para renombrar;
  - el subrayado es animado y la barra, compacta;
  - podés soltar carpetas en el riel.
- **VoiceOver** lee las tarjetas, las filas, el riel y las pestañas.

### Riel y sidebar (fijados, orden y anillo único)

- **Orden en cuatro grupos**, el mismo en el riel, el árbol, ⌃⌘1…9, ⌥⌘↓/↑, ⌘K y el menú Ir:
  1. **Fijados**: clic derecho › «Fijar arriba» o «Dejar de fijar». Después va un divisor.
  2. **Activos**: tienen algo prendido (un agente trabajando, pidiendo permiso o con algo sin ver, una Terminal con un proceso, un comando corriendo) o una sesión usada hoy (le escribiste o la creaste).
  3. **Apagados**: se ven sin color y un poco transparentes.
  4. **«Terminales»**, siempre al final.

  Dentro de cada grupo manda tu orden.
- **Abrir un proyecto apagado no lo prende**, así no salta debajo del puntero. Pasa a los activos recién cuando le escribís.
- **Al cambiar el día**, lo de ayer pasa solo a los apagados. Hive se entera por un aviso del sistema, sin timers.
- **Arrastrar para reordenar**, en el árbol y (nuevo) en el riel, siempre dentro del grupo: entre grupos el puntero muestra que no se puede. El arrastre es solo de Hive: soltarlo sobre una terminal no escribe nada, y soltar carpetas sigue agregando proyectos.
- **Un solo aro, solo de estado:** arco miel que gira, naranja lleno o verde. Ya no está el borde del color del proyecto, que queda como fondo tenue detrás del logo. Un proyecto apagado nunca tiene aro.
- **Un solo globito** (`ActivityBadge`), igual en el Inicio, el árbol, el riel y el encabezado del Resumen. Si hay permisos dice «!1» en naranja y cuenta solo esos; si no, dice cuántas sesiones te esperan. El detalle completo está en la ayuda y en VoiceOver.
- El menú Ir se rearma solo cuando cambia el orden o un nombre.

### Robustez y bugs corregidos

**Git y worktrees**
- Las carreras de la revisión de git: un checkout o un proyecto agregado durante una revisión lenta ya no se pierde, y crear una rama no la duplica.
- Quitar un worktree cuya carpeta falta ya no corre `git worktree prune` global, que rompía los worktrees de un disco desconectado.
- **Los worktrees borrados por fuera se van solos de Hive**, con sus sesiones y sus comandos terminados, **salvo los que tienen algo corriendo**: esos muestran el aviso y se van cuando termina.
- Quitar una rama corta primero sus sesiones, sus comandos, los lanzamientos en curso y un «Publicar» o «Traer» que esté corriendo. Recién después borra la carpeta.
- No se lanzan sesiones con la rama guardada hasta que git la confirma.
- Una revisión en medio de un checkout de Hive ya no avisa que la rama «cambió por fuera».
- Un push con un pre-push largo o un switch con un post-checkout pesado ya no se cortan a los 2 minutos.
- «Crear primer commit» ya no mete lo que estaba preparado (por ejemplo, un `.env`).

**Procesos y comandos**
- Detener y reiniciar un comando enseguida ya no mata al nuevo.
- Detener corta los shells que ignoran SIGTERM, y el corte por tiempo mata a todo el grupo (ssh, hooks).
- Limpiar la salida de un comando ya no le manda Ctrl+L al programa.
- Correr de nuevo un comando usa la carpeta actual de su rama.

**Agentes**
- Ya no quedan permisos colgados:
  - Esc saca de «Necesita permiso»;
  - otra herramienta en paralelo no la saca mientras el diálogo está abierto;
  - un plan o una pregunta ya no dicen «Pide permiso para ExitPlanMode».
- Los subagentes de Codex ya no cambian el thread ni el historial.
- Responder desde el aviso no aprueba un permiso sin querer y no manda caracteres de control.

**Datos**
- Un `.mcp.json` roto no se reescribe: los MCP ya no se borran.
- Un `state.json` ilegible no se pisa, uno dañado avisa dónde quedó la copia y un error al guardar avisa una sola vez.
- Una copia del transcript que llega tarde no revive una sesión eliminada.
- Tu `state.json` actual carga igual: los campos nuevos (fijados, nombre automático, rama guardada) se leen como opcionales.

**Caídas y cuelgues**
- Hive ya no se cae con porcentajes de uso NaN, infinitos o enormes, ni con un `background_tasks` fuera de rango.
- Un `config.toml` de Codex con un cierre raro ya no cuelga la lectura.
- Lanzar sesiones y leer MCP, sugerencias, logos y transcripts ya no traban la app: corren fuera del hilo principal. El uso de Codex ya no recorre el rollout entero cada 30 s.

**Interfaz**
- En las pestañas compactas, la rama ya no queda reducida a una letra.
- ⌘K con `?` desde el historial: lo que escribís ya no borra el `?`, y el cursor espera a que el campo tenga el texto.
- Abrir un proyecto apagado ya no lo hace saltar de lugar, y el menú Ir no se rearma con cada cambio de estado.
- «Tu turno» ya visto se ve hueco en la barra, igual que en el árbol y en las pestañas.

---

## 3. Atajos de teclado y ajustes nuevos

### Atajos (de `HiveCommands.Shortcut`)

| Atajo | Qué hace | Menú |
|---|---|---|
| ⌘O | Agregar proyecto (podés elegir varias carpetas) | Archivo |
| ⇧⌘W | Cerrar la ventana | Archivo |
| ⌘T | Nueva sesión del mismo agente que la abierta (o Claude) en la rama actual; si no está instalado, avisa cómo instalarlo | Sesión |
| ⇧⌘N | Nueva rama… | Sesión |
| ⌘R | Reiniciar la sesión, o reanudarla si terminó (pregunta si está en algo) | Sesión |
| ⌘. | Detener la sesión (pregunta si está en algo; en una hoja, cancela) | Sesión |
| ⌘W | Archivar la sesión abierta (pregunta si está en algo; en Ajustes o en otra ventana, cierra) | Sesión |
| ⌥⌘1 / ⌥⌘2 | Mostrar u ocultar el Historial / los Cambios | Sesión |
| ⇧⌘H | Inicio | Ir |
| ⌘K | Buscar (con `>`, acciones; con `?`, el historial de todas las sesiones) | Ir |
| ⌘J | Siguiente que te espera: primero la que pide permiso, después la que terminó hace más | Ir |
| ⇧⌘] / ⇧⌘[ | Sesión siguiente / anterior (da la vuelta) | Ir |
| ⌘1 … ⌘9 | Pestaña 1 a 9 del proyecto abierto | Ir |
| ⌥⌘↓ / ⌥⌘↑ | Proyecto siguiente / anterior, en el orden que se ve | Ir |
| ⌃⌘1 … ⌃⌘9 | Proyecto 1 a 9, en el orden que se ve (fijados, activos, apagados y «Terminales») | Ir |
| ⌘F, ⌘G, ⇧⌘G, ⌘E | Buscar en la terminal, siguiente, anterior y usar la selección | Edición › Buscar |
| ⌥⌘K | Limpiar la terminal (en los agentes se usa `/clear`) | Edición |
| ⌘Z | Deshacer: archivar, quitar un proyecto, borrar un comando o quitar un MCP | Edición |
| ⌘+ (o ⌘=), ⌘−, ⌘0 | Agrandar, achicar y volver al tamaño normal del texto de las terminales | Visualización |

**En la terminal**

| Tecla | Qué hace |
|---|---|
| ⌥ + letra | ñ, tildes, @, `[ ] { } \| \ ~` (con «Tecla ⌥ Option» en «Escribe caracteres») |
| ⌥← / ⌥→, ⌥⌫ | Saltar de a palabras y borrar una palabra |
| Shift+Enter, ⌥Enter | Salto de línea en un agente, sin enviar |
| Esc | En un agente que trabaja o pide permiso, frena el turno (pasa a «Tu turno») |
| ⌘clic | Abre la ruta (en su línea), la carpeta o la URL bajo el puntero |
| ⌘V | Pega texto, rutas de archivos copiados o una imagen (en un agente) |
| Clic derecho | Menú con Copiar, Pegar, Buscar…, Limpiar, enlaces, Finder y tamaño |

**En otros lugares:** en ⌘K, ↑↓, ↵ y esc. En el diff, ↑ y ↓ pasan de archivo, y Esc cancela la confirmación de un conflicto. En el sidebar, ⏎ abre la sesión con el foco en la terminal. En la vista compacta, doble clic en una pestaña la renombra.

### Ajustes nuevos (Hive › Ajustes)

| Pestaña | Ajuste | Opciones (por defecto) |
|---|---|---|
| General | **Claude y Codex en la terminal normal** (antes era solo Claude) | Sí |
| General | **Mostrar uso de Claude en su barra** | Sí |
| General | Aviso si tu `notify` de Codex tiene un formato que Hive no entiende | — |
| Terminal | **Fuente** | Monoespaciadas instaladas (SF Mono) |
| Terminal | **Tamaño** (también ⌘+, ⌘− y ⌘0) | 9 a 28 pt (13) |
| Terminal | **Cursor** y «Que parpadee» | Bloque, Barra o Subrayado (bloque que parpadea) |
| Terminal | **Tema** | Seguir al sistema, Oscuro o Claro (sistema) |
| Terminal | **Tecla ⌥ Option** | «Escribe caracteres (ñ, tildes, @)» o «Funciona como Meta (Alt)» (caracteres) |
| Terminal › Editor | **Abrir archivos con** (⌘clic y «Abrir en el editor») | El primero instalado; Android Studio y Xcode se eligen solos según el proyecto |
| Avisos | Estado de los avisos de macOS, con «Abrir Ajustes del Sistema» si están desactivados | — |
| Avisos | **Sonido en los avisos** | Sí |

Hive también recuerda solo algunas cosas: el modo y la primera sesión de «Nueva rama», el panel abierto de la sesión (Historial o Cambios), los proyectos fijados y si los «Sugeridos» de MCP de cada proyecto quedaron abiertos.

---

## 4. Lo que falta

### a) Pendiente de esta ronda

| Qué | Por qué quedó |
|---|---|
| Las abreviaturas «5h», «sem» y «ctx» en las barritas del sidebar y en la línea de estado de Claude | Escritas enteras no entran en el sidebar angosto. La ayuda ya dice «5 horas» y «semana». Queda a tu decisión. |
| Unos 120 grises del sistema (`.secondary`) fuera de las tarjetas, que en claro dan ~3,9:1 | Se corrigió donde hay datos sobre tarjetas. Para llegar a 4,5:1 en toda la app alcanza con un reemplazo mecánico por `Theme.secondaryText`. |
| El tinte ámbar en interruptores y radios | Es una decisión de diseño y en las capturas no se puede juzgar (las ventanas fuera de pantalla los dibujan grises). |
| `git switch` y `worktree add` tienen 30 min de límite pero no se pueden cancelar desde la UI | «Publicar» y «Traer» sí se cancelan. Para estos dos queda a tu decisión si vale la pena una X. |
| El divisor de los fijados ocupa una fila entera en el árbol | La lista de macOS impone un alto mínimo de fila. Se probaron tres formas y ninguna lo achica. En el riel mide 1 pt. |
| Las tarjetas de sesiones dormidas y «>nueva» de ⌘K se siguen ofreciendo en ramas bloqueadas o sin carpeta | Terminan en una alerta clara, y son de otras vistas. |
| Historial: en el ancho mínimo, la divisoria deja el «·» al final de la primera línea. En ⌘K se ve el día sin la hora y los resultados no se agrupan por sesión | Agregar la hora cambia subtítulos que fijan tests de otro paquete. Es menor. |
| La notificación de un plan o de una pregunta tiene el subtítulo «Necesita permiso» | El cuerpo sí dice «Tiene un plan listo…» o «Te hace una pregunta…». Se puede refinar. |
| Los chips de «Primera sesión» tienen el borde cortado | Ya venía así de antes. |
| Internos menores: `AgentAvailability` vive en un registro aparte y no dentro de `AppStore`. Con un thread nuevo de Codex se lee `~/.codex` en el hilo principal (después queda en caché). La tabla de códigos de error está repetida en `AgentEvents`. La tarjeta que ya no repite «Trabajando» no tiene test propio. | Funcionan bien. Son limpieza para otra ronda. |

### b) Para otra ronda (lo que el plan dejó para después)

Esfuerzo: **S** chico, **M** mediano, **L** grande.

| Idea | Por qué no entró | Esfuerzo |
|---|---|---|
| Fetch automático, comparación con main (adelante/atrás, «Mergeada») y estado del MR y del pipeline | Esta ronda dejó Traer, Publicar y «Crear MR» a mano. El fetch periódico toca el timer del store y las tarjetas. | M |
| Terminar rama: detectar las mergeadas y limpiar el worktree, Herd (unsecure/unlink), la rama local y las sesiones | Depende de la comparación con main y del script de cierre, que llegó en esta ronda. | M |
| Preparar, quitar, descartar y commitear desde el panel de Cambios | En el día a día los commits los hacen los agentes. | M |
| Prompt inicial al crear una rama o una sesión, y perfiles (`--permission-mode`, modelo, esfuerzo) | Pide cambios coordinados en la hoja, el lanzador y el store, y falta verificar la sintaxis de `gemini -i`. | M |
| Prompts guardados con variables y envío a varias sesiones | Necesita una API para mandar texto a una sesión y UI en la sesión y en las tarjetas. | M |
| Usar los hooks de Codex (SessionStart, PermissionRequest, Interrupt) en lugar del notify | Es grande, y hay que probar el flujo de confianza de hooks sin prompts pagos. | L |
| Comentar líneas del diff y mandárselas al agente | Necesita la misma API para mandar texto, y conviene con el diff en su propia ventana. | M |
| Diff en una ventana propia que se actualiza en vivo | Cambia cómo se presenta la escena y el store. Por ahora la hoja se puede agrandar. | M |
| Puntos de control por prompt (`refs/hive`) | Toca el índice de git en cada prompt y puede perder datos si sale mal: necesita su propia ronda, con tests de git real. | M |
| La misma tarea con Claude y Codex en paralelo, para comparar | Depende del prompt inicial. | L |
| Plantilla común para las hojas | Las hojas eran de cuatro paquetes distintos. La unificación va sobre la base integrada. | M |
| OSC 7501 y OSC 9/777 como fuente de estado del agente | Primero hay que registrar qué manda Claude en la práctica. | M |
| Detectar la URL del servidor en la salida de los comandos (Vite, artisan serve, Next) | «Abrir sitio» ya cubre Herd y polyscope. Esto necesita conectar la salida de los comandos con el store. | S |
| Variables del `.zshrc` para los agentes y los MCP (`HERD_PHP_*`, `NVM_DIR`) | Hay que decidir con cuidado qué excluir y probarlo con el shell real. Por ahora solo se agregó `ANDROID_HOME`. | M |
| Separar `AppStore` en objetos (GitMonitor, controlador de comandos, presentación) y achicar lo público de HiveKit | Por ahora solo se partió en extensiones. | L |
| Comandos que arrancan solos con la rama | Necesita un campo en el modelo y lógica de ciclo de vida en el store. | S |
| Una base de datos propia por worktree | Es opcional y riesgosa: depende del MySQL de Herd. | S |
| Un aviso único cuando un límite de uso pasa el 90 % | Hay que conectar el monitor de uso con los avisos. | S |
| FSEvents sobre `.git` para refrescar por evento | Esta ronda ya bajó el costo con concurrencia, modo inactivo y límites de tiempo. | M |
| Submenú «Archivadas (n)» en el clic derecho de la rama | Las archivadas ya se alcanzan desde ⌘K y desde la vista de rama. | S |

### c) Descartado a propósito

| Qué | Por qué |
|---|---|
| Dibujar los logos | Se usan los originales de `LogoAssets.swift`. |
| Una bandeja «Te esperan» en un popover | El Inicio y ⌘J cubren lo mismo. |
| Pasar ⌘K a ⌘P, o que ⌘K limpie la terminal como en Terminal.app | Usás ⌘K para buscar. Limpiar está en ⌥⌘K y en el clic derecho de la terminal, y hay un test que lo fija. |
| Ligaduras de fuente | SwiftTerm no las soporta. |
| Sacar `php artisan serve` de las sugerencias | Se mantiene. |
| `gh` para los PR | Tus remotos son de GitLab y no hay `gh` ni `glab`: se abre la URL del MR nuevo. |
| Un grupo «retenido» para el proyecto recién abierto | Se probó: al soltarlo, el salto solo pasaba al clic siguiente y podía mover el ícono que estabas tocando. |
| tmux para que las sesiones sobrevivan | No está instalado y rompería el scroll y el filtro de `/clear` (ver la idea 1). |

### d) Probado solo con tests: conviene probarlo a mano

| Qué | Cómo probarlo | Por qué no alcanza el test |
|---|---|---|
| **Teclado latino** | En los teclados ABC y Latinoamericano: ⌥e y después a → «á», ⌥n y después n → «ñ», la @ y los corchetes. | Los eventos simulados no pasan por la composición de teclas de macOS. |
| **Grok** | Instalalo, abrí una sesión de Grok, pedile algo y salí: tiene que pasar a «Trabajando» y después a «Tu turno» con aviso. Reiniciala: tiene que retomar la misma conversación. Fijate en `grok inspect` que aparezca el hook de Hive y si Grok lee el `.mcp.json` del proyecto. | Grok no está instalado en esta Mac: el formato de sus hooks y de `~/.grok/sessions` sale de la documentación de xAI. |
| **Shift+Enter** | En Claude, Codex y Gemini: hace salto de línea sin enviar, y después de un `/clear` lo anterior sigue en el scroll. | Probado con eventos simulados, no con los agentes reales. |
| **Notificaciones con respuesta** | Con Hive.app: «Responder» a un aviso de turno → la sesión pasa a «Trabajando». Con la sesión pidiendo permiso → la abre y deja el texto en el portapapeles. Probá también el sonido. | Los tests nunca llaman al centro de avisos de macOS, y los avisos solo existen dentro de un `.app`. |
| **Herd** | En un proyecto Laravel servido por Herd, una rama nueva «Junto al proyecto»: tiene que abrir `https://<repo>-<rama>.test`, con el `.env` y su `APP_URL`, «Preparar» (y `herd secure` si el principal tiene certificado) y «Abrir sitio». | Los tests usan una configuración de Herd falsa en una carpeta temporal. |
| **Publicar a GitLab** | «Publicar rama», «Crear MR en GitLab» (abre el MR nuevo), «Traer cambios», y cancelar con la X durante un pre-push lento. | Los tests usan repos locales y un git falso lento, no GitLab. |
| **Workflow en segundo plano** | Pedile a Claude algo que lance un workflow o subagentes en segundo plano y salí de la sesión: tiene que seguir en «En segundo plano…», sin globito, y avisarte recién cuando Claude cuente que terminó. | Los hooks están simulados con el formato que documenta Claude Code 2.1.301. |
| **El riel con el cambio de día** | Dejá Hive abierta pasada la medianoche: lo que solo se usó ayer tiene que pasar a los apagados sin tocar nada. | El aviso del sistema se simula en el test. |
| **Arrastrar en el riel** | Reordenar arrastrando dentro de un grupo, y soltar una carpeta sobre un ícono del riel. | Un arrastre real necesita mover el mouse. |
| **Los apagados sin color** | Que los íconos apagados se vean casi grises pero reconocibles, en claro y en oscuro. | Las capturas no aplican el filtro de saturación: ahí se ven con todo el color. |
| **Terminal con un proceso** | `npm run dev` en una Terminal: ⌘W pregunta. Después de Ctrl+C, ya no. | Está probado con un zsh real, pero no con tu shell y tus comandos. |
| **⌘W en la ventana principal** | ⌘W archiva en la ventana principal y cierra en Ajustes. | Depende de que la ventana tenga el identificador «main». |
| **«Copiar .env…» en Nueva rama** | Sin nada para copiar, el interruptor tiene que verse apagado y deshabilitado. | El código lo apaga (y tiene test), pero en una captura salió prendido, probablemente porque la animación no termina fuera de pantalla. |

### Ideas para más adelante (pediste no arrancarlas todavía)

#### 1. Sesiones que sobreviven a cerrar Hive

- **Hoy:** cerrar Hive corta las sesiones. Al volver, solo se reanuda la conversación (`claude --resume`, `codex resume`). Lo que estaba corriendo se pierde.
- **La idea:** un host de sesiones, `hive-host`, que es un proceso aparte dueño de los PTYs.
  - Lanza cada agente con `posix_spawn` y `setsid`, así no muere con la app.
  - Habla con Hive por un socket Unix.
  - Guarda un buffer crudo de la salida de cada sesión para redibujar la terminal al reconectar.
- **Qué ganás:** al cerrar, reiniciar o actualizar Hive, los agentes siguen trabajando, y al volver la terminal aparece tal cual estaba.
- **Por qué sin tmux:** no está instalado, y metería su propia pantalla en el medio, lo que rompe el scroll de SwiftTerm y el filtro de `/clear`.
- **A tener en cuenta:** el host necesita su propio ciclo de vida (arrancarlo, detectar si quedó viejo después de una actualización y apagarlo cuando no hay sesiones). También el reparto de tamaños de ventana entre el host y la terminal, y que los avisos y los hooks sigan llegando aunque Hive esté cerrada.

#### 2. Hive en la nube personal

- **La idea:** el mismo `hive-host` en una máquina siempre prendida. Se recomienda una Mac mini, por Herd, los emuladores e iOS. Con Tailscale, controlás las sesiones desde cualquier Mac con la misma UI.
- **Opcional:** traer una rama a la Mac local para correr emuladores y tests.
- **Contras:**
  - la seguridad: el host da acceso a terminales con tus credenciales;
  - el stack duplicado: Herd, bases de datos y SDKs en las dos máquinas;
  - git, el diff y el historial tienen que pasar por el host, porque hoy Hive los lee del disco local.
- **Depende de la idea 1.**

---

## 5. Cómo probarlo

### Tests

```bash
scripts/test.sh                              # todo
scripts/test.sh HiveCoreTests                # solo el core
scripts/test.sh StoreProjectOrder            # un filtro cualquiera
scripts/test.sh --snapshots /tmp/capturas    # además guarda capturas PNG en claro y en oscuro
```

| Suite | Tests | Suites |
|---|---|---|
| HiveCoreTests | 480 | 66 |
| HiveKitTests | 382 | 52 |
| **Total** | **862** | |

Al empezar la ronda había unos 200 tests (unos 145 en HiveCore y 57 en HiveKit). El build limpio con `--build-tests` da cero warnings. Ningún test lee tu estado real (`~/.claude`, `~/.codex`, `~/.gemini`, Herd o Application Support), usa `UserDefaults.standard` ni llama al centro de avisos de macOS.

### Capturas

Las últimas (164 PNG, en claro y en oscuro) quedaron en
`/private/tmp/claude-501/-Users-lucianosanchez/1b2a302f-c49d-4639-a59b-545bf7de84ff/scratchpad/ultra-snapshots/final`.
Es una carpeta temporal: para regenerarlas, usá `scripts/test.sh --snapshots <carpeta>`. Las del riel son `riel-01` a `riel-03`, los estados están en `estados-muestrario`, los flujos nuevos en `flujos-01` a `flujos-04` y la rama sin carpeta en `rama-worktree-faltante`.

Algunas cosas son defectos de dibujar fuera de pantalla, no de la app: la terminal sale en blanco o negro, la selección del sidebar sale negra, los interruptores se ven grises y no se aplica la saturación.

### Correr la app sin tocar tu estado

```bash
HIVE_HOME="$(mktemp -d)" swift run Hive
```

`HIVE_HOME` hace que Hive use esa carpeta en lugar de `~/Library/Application Support/Hive`.

- **Para probar los avisos con «Responder»** hace falta el `.app`. Armalo con `scripts/build-app.sh` y abrilo con `HIVE_HOME="$(mktemp -d)" build/Hive.app/Contents/MacOS/Hive`. Conviene hacerlo con la Hive instalada cerrada, porque las dos comparten el identificador de la app.
- **Para instalarla de verdad:** cerrá Hive (las sesiones se cortan, pero las conversaciones se reanudan), traé la rama `ultra/integration` a tu repo y corré `scripts/build-app.sh --install`.
