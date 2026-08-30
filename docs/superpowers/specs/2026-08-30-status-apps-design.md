# Status Apps — diseño

Fecha: 2026-08-30

## Problema

Tres bundlers de Metro quedaron corriendo diez días sin que nadie lo notara, ocupando
13,5 GB de footprint entre los tres y empujando el swap a 19 GB de 20 GB. Activity Monitor
mostraba tres procesos llamados `node` sin forma de distinguirlos: no expone el puerto que
escuchan ni el directorio desde el que se lanzaron.

La app resuelve la identificación: qué servidores de desarrollo están vivos, en qué puerto,
desde qué proyecto y cuánta memoria real ocupan.

## Alcance

Una app de menu bar que lista **solo servidores de desarrollo**, con acciones de
stop, clean y rerun sobre cada uno.

Explícitamente fuera de alcance:

- Alertas, umbrales y notificaciones. La app es pasiva: informa cuando se abre el menú.
- Procesos que no son de desarrollo (Logitech, `adb`, `wineserver`, agentes del sistema).
- Gráficos históricos o series de tiempo.

## Arquitectura

App AppKit con `NSStatusItem`, empaquetada como `.app` con `LSUIElement = true` para que no
aparezca en el Dock. Firma ad-hoc y sin sandbox: `libproc` necesita leer otros procesos del
mismo usuario.

Se descartó SwiftUI `MenuBarExtra` porque los submenús por servidor se arman dinámicamente
según el tipo, y `NSMenu` da control directo sobre eso.

El código se separa en dos targets para que la lógica sea testeable sin levantar la interfaz:

- `StatusAppsCore` — biblioteca. Escaneo, clasificación, acciones, persistencia.
- `StatusApps` — ejecutable. Status item, menú, ciclo de vida.

### Módulos

| Módulo | Responsabilidad | Depende de |
|---|---|---|
| `ProcessScanner` | Envuelve `libproc`. Devuelve `[RunningProcess]` sin aplicar ninguna política. | syscalls |
| `DevServerClassifier` | Función pura `[RunningProcess] -> [DevServer]`. Toda la curación y el armado de etiquetas. | nada |
| `SystemMemory` | Uso de swap vía `sysctl`. | syscalls |
| `ServerActions` | stop, clean, rerun, attach. Único módulo que lanza subprocesos. | tmux, watchman |
| `KnownServersStore` | Persiste el último estado visto de cada servidor. | disco |
| `MenuBuilder` | `[DevServer]` + swap -> `NSMenu`. Sin acceso al sistema. | nada |
| `AppDelegate` | Status item, timer, cableado. | todos |

La curación vive aislada en un módulo puro a propósito: es la parte que cambia cuando aparece
un runtime nuevo, y así se ajusta sin tocar el escaneo ni la interfaz.

### Escaneo

Nada de shelling out en el camino caliente. Se usan las mismas syscalls que `lsof` por dentro:

- `proc_listpids` para enumerar procesos.
- `proc_pidinfo(PROC_PIDTBSDINFO)` para uid, pgid y arranque. Filtra por uid antes de seguir.
- `proc_pidinfo(PROC_PIDLISTFDS)` + `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)` para los sockets
  TCP en estado `TSI_S_LISTEN`.
- `proc_pid_rusage(RUSAGE_INFO_V4)` para `ri_phys_footprint`, el mismo número que muestra
  Activity Monitor.
- `sysctl(KERN_PROCARGS2)` para el argv completo.
- `proc_pidinfo(PROC_PIDVNODEPATHINFO)` para el cwd.

Validado contra `lsof`: mismos procesos y mismos puertos, en milisegundos en vez de dos segundos.

## Reglas de curación

Un proceso es dev server si tiene al menos un socket TCP en LISTEN del usuario **y**
el ejecutable está en la allowlist (`node`, `bun`, `deno`, `python3`, `ruby`, `java`,
`postgres`, `redis-server`, `php`) **o** el argv menciona
`expo`, `metro`, `vite`, `next`, `webpack`, `rails`, `uvicorn` o `gunicorn`.

Es allowlist, no denylist: `adb`, `wineserver` y los agentes de Logitech quedan afuera porque
no están en la lista, no porque se los excluya uno por uno. No hay que perseguir cada app
nueva que abra un puerto.

Postgres entra: es una dependencia de desarrollo legítima. Sacarlo es borrar una línea.

### Etiquetas

Derivadas del cwd, en este orden:

1. Si el path contiene `/.worktrees/<wt>`, la etiqueta es `<repo>/<wt>`.
2. Si no, el basename del cwd.
3. Si el cwd es `/`, está vacío o es ilegible, el nombre del ejecutable.

## Acciones

- **Stop** — `SIGTERM` al process group, no al pid. Un Metro es `yarn start` que lanza `node`;
  matar solo el hijo deja el padre huérfano. A los cinco segundos, si sigue vivo, el menú
  ofrece `SIGKILL`.
- **Clean** — según el tipo. Metro borra `$TMPDIR/metro-*`, `haste-*` y `react-*`, más el
  `.expo` del proyecto, y corre `watchman watch-del <cwd>`. Los demás tipos lo tienen
  deshabilitado en lugar de inventar una receta.
- **Rerun** — `tmux new-session -d -s <tipo>-<etiqueta> -c <cwd>` corriendo el argv original
  bajo un shell de login, para que tome nvm y el PATH del usuario. Si la sesión ya existe,
  se baja primero.
- **Attach** — abre Terminal.app con `tmux attach -t <sesión>`.

## Persistencia

Un JSON en `~/Library/Application Support/StatusApps/known.json` guarda el último estado visto
de cada servidor: etiqueta, tipo, cwd, argv y puerto. Los que ya no corren aparecen en una
sección "Recientes" con una sola acción, Rerun.

Es la única persistencia de la app, y existe porque sin ella "rerun" sería apenas un restart
de algo que ya está vivo. El valor está en relanzar lo que se murió.

### Identidad de un servidor

La identidad es `tipo + cwd + argv`, no `tipo + cwd + etiqueta`. Un mismo directorio puede correr
varios servidores: la máquina de referencia tenía dos procesos `bun` en `toto/apps/api`, en los
puertos 3000 y 3999, y dos más llamados `scratchpad`. Con la etiqueta como clave se colapsaban
en una sola entrada.

Por la misma razón el nombre de sesión de tmux lleva el puerto (`bun-api-3000`, `bun-api-3999`),
o un hash corto del cwd cuando no hay puerto: si colisionaran, un Rerun sobre uno bajaría la
sesión del otro.

## Manejo de errores

- Cualquier llamada por pid que devuelva `EPERM` — procesos de otros usuarios — se saltea en
  silencio. El scanner nunca propaga errores a la interfaz: degrada a menos filas.
- Sin `tmux`, Rerun y Attach quedan deshabilitados con un tooltip que lo explica.
- Sin `watchman`, ese paso de Clean se omite y el resto se ejecuta igual.

## Tests

`DevServerClassifier` y el armado de etiquetas se testean con fixtures capturados de una máquina
real y transcriptos a literales de Swift: son funciones puras, no tocan el sistema y corren en
milisegundos. Los casos que importan son los paths de worktree, el cwd vacío, el cwd en `/` y los
procesos que deben quedar fuera de la allowlist.

`ProcessScanner` tiene un test de integración que abre un socket de escucha y verifica que el
proceso de test se encuentra a sí mismo, con ese puerto y con un footprint mayor a cero.

`ServerActions` no se testea de forma automática porque muta el sistema. Se valida a mano.


## Resultado

Implementado y verificado contra el sistema real: mismos procesos y mismos puertos que `lsof`,
con un escaneo de unos 5 ms sobre 530 procesos. La app ocupa unos 11 MB. 41 tests en verde.
