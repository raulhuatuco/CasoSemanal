from pathlib import Path
import shutil

def copiar_carpeta(origen: Path, destino: Path, nuevo_nombre: str, sobrescribir: bool = False) -> None:
    """
    Copia una carpeta completa desde 'origen' a 'destino' con un nombre distinto.

    origen: Path de la carpeta origen
    destino: Path de la carpeta destino
    nuevo_nombre: Nombre que tendrá la carpeta copiada
    sobrescribir: Si True, elimina el destino si ya existe
    """
    origen_path = Path(origen)
    destino_path = Path(destino) / nuevo_nombre

    if not origen_path.is_dir():
        raise FileNotFoundError(f"La carpeta origen no existe: {origen_path}")

    if destino_path.exists():
        if sobrescribir:
            shutil.rmtree(destino_path)
        else:
            raise FileExistsError(f"La carpeta destino ya existe: {destino_path}")

    shutil.copytree(origen_path, destino_path)
    