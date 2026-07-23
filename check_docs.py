from pathlib import Path


def find_missing_docs(device_folder="device", docs_folder="documentation"):
    device_path = Path(device_folder)
    docs_path = Path(docs_folder)

    # Check if directories exist to avoid errors
    if not device_path.exists():
        print(f"Error: The folder '{device_folder}' does not exist.")
        return
    if not docs_path.exists():
        print(f"Error: The folder '{docs_folder}' does not exist.")
        return

    # Create sets of the file names without their extensions (.stem)
    py_files = {file.stem for file in device_path.glob("*.py")}
    pdf_files = {file.stem for file in docs_path.glob("*.pdf")}

    # Find files in the device folder that aren't in the documentation folder
    missing_docs = py_files - pdf_files

    # Output the results
    if not missing_docs:
        print("Great news! All Python files have matching PDF documentation.")
    else:
        print(f"Found {len(missing_docs)} Python file(s) missing PDF documentation:")
        for name in sorted(missing_docs):
            print(f"- {name}.py (Missing: {name}.pdf)")


if __name__ == "__main__":
    # You can change the folder names here if your paths are different
    find_missing_docs("device", "documentation")
