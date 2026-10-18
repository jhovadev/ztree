# ztree

Listado recursivo de directorios en forma de árbol, escrito en **Zig 0.16** y sin
dependencias externas.

```
$ ztree --depth 2 src
src
├── cli.zig
├── colors.zig
├── main.zig
├── root.zig
└── tree.zig

0 directories, 5 files
```

## Características

- Recorrido recursivo con conectores de árbol correctos (`├──`, `└──`, `│`).
- Directorios primero y orden alfabético insensible a mayúsculas.
- Colores ANSI automáticos cuando la salida es una terminal.
- Respeta `NO_COLOR` y `CLICOLOR_FORCE`; se puede forzar con `--color always`.
- Tamaños legibles (`--size`): `512 B`, `1.5 KiB`, `3.0 MiB`.
- Muestra enlaces simbólicos con su destino y **nunca los sigue**, por lo que
  no puede entrar en ciclos.
- Los errores de permisos o de lectura se reportan como advertencias y el
  recorrido continúa; el resumen incluye el número de errores.
- Opciones para ocultos (`--all`), solo directorios (`--dirs-only`), profundidad
  máxima (`--depth`) y salida ASCII (`--ascii`).
- Biblioteca reutilizable además del ejecutable: `ztree.tree` y `ztree.cli`.

## Requisitos

- Zig **0.16.0** (véase `minimum_zig_version` en `build.zig.zon`).
- Compila en las plataformas soportadas por Zig; las pruebas de enlaces
  simbólicos se omiten en Windows.

Comprueba la versión instalada:

```sh
zig version
```

## Compilación

```sh
# Compilación de desarrollo (por defecto)
zig build

# Compilación optimizada y segura
zig build -Doptimize=ReleaseSafe

# El binario queda en:
./zig-out/bin/ztree
```

El proyecto también puede instalarse en otro prefijo:

```sh
zig build --prefix /usr/local
```

## Uso

```
ztree [OPTIONS] [PATH]
```

`PATH` es opcional y por defecto es el directorio actual.

### Ejemplos

```sh
# Directorio actual
ztree

# Un directorio concreto, incluyendo ocultos
ztree --all /ruta/al/proyecto

# Limitado a dos niveles y sin colores
ztree --depth 2 --color never src

# Solo directorios
ztree --dirs-only .

# Con tamaños de archivo
ztree --size -L 1 .

# Salida estable para scripts o terminales sin Unicode
ztree --ascii --no-color .
```

### Opciones

| Opción | Descripción |
| --- | --- |
| `-a`, `--all` | Incluye entradas ocultas (nombres que empiezan por `.`). |
| `-d`, `--dirs-only` | Lista únicamente directorios. |
| `-s`, `--size` | Muestra tamaños legibles junto a cada archivo. |
| `-L`, `--depth <N>` | Limita la recursión a `N` niveles (`1` = hijos directos). |
| `-c`, `--color <WHEN>` | `auto`, `always` o `never` (por defecto `auto`). |
| `--no-color` | Equivale a `--color never`. |
| `--ascii` | Usa `\|--` y `` `-- `` en lugar de caracteres Unicode. |
| `--no-summary` | Omite la línea de resumen. |
| `-h`, `--help` | Muestra la ayuda. |
| `-V`, `--version` | Muestra la versión. |

### Variables de entorno

| Variable | Efecto |
| --- | --- |
| `NO_COLOR` | Desactiva el color cuando `--color=auto`. |
| `CLICOLOR_FORCE` | Fuerza el color cuando su valor no es `0`. |

### Códigos de salida

| Código | Significado |
| --- | --- |
| `0` | Éxito (también si un consumidor cierra la tubería, p. ej. `ztree \| head`). |
| `1` | Uso incorrecto de la línea de comandos. |
| `2` | La ruta indicada no se pudo leer. |

## Desarrollo

```sh
# Ejecutar sin instalar
zig build run -- --depth 2 src

# Pruebas unitarias del parser y del renderizador
zig build test

# Formatear el código en sitio
zig build fmt

# Verificación completa: formato + pruebas
zig build check
```

## Estructura del proyecto

```
build.zig          Grafo de compilación (run/test/fmt/check)
build.zig.zon      Metadatos del paquete
src/main.zig       Punto de entrada: argumentos, writers y códigos de salida
src/root.zig       Superficie pública de la biblioteca
src/cli.zig        Parser de opciones y texto de ayuda
src/tree.zig       Recorrido recursivo, ordenación y renderizado
src/colors.zig     Secuencias ANSI
```

## Decisiones de diseño

- **Iteración manual** con `Io.Dir.iterate` en lugar de `Io.Dir.walk`: permite
  ordenar cada directorio y saber cuál es el último hijo antes de imprimir los
  conectores.
- **Enlaces simbólicos no seguidos**: el destino se lee con `readLink` solo para
  mostrarlo. Esto elimina por construcción los ciclos de directorios.
- **Tope de profundidad defensivo** de 1024 niveles para evitar desbordar la
  pila con árboles patológicos; si se alcanza, se emite una advertencia.
- **Salida con búfer** (`Io.File.Writer`) y un único *flush* al final, salvo
  antes de cada advertencia para conservar el orden.
- **Errores no fatales**: un subdirectorio ilegible genera una advertencia en
  `stderr`, incrementa el contador de errores y el resto del árbol se sigue
  mostrando.

## Licencia

MIT. Véase [LICENSE](LICENSE).
