# Merge Audiobook

This script merges a series of audio files (currently m4a/m4b only) into a single audiobook.

It will attempt to preserve any existing chapters in each of the files if they exist and creating them with the filenames if they do not.

It leverages FFmpeg for the merging process and a bit of jq to process the metadata.

## Prerequisites

- FFmpeg ffprobe
- jq

## Building the Docker Image

1. **Clone the Repository:**

   ```bash
   git clone https://github.com/totallyGreg/merge_audiobook.git
   cd merge_audiobook
   ```

2. **Build the Docker Image:** Navigate to the repository directory and execute the following command:

   ```bash
   docker build -t merge-audiobook .
   ```

   - `-t merge-audiobook`: This tags the image with the name "merge-audiobook". You can choose a different name if you prefer.
   - `.`: This specifies that the Dockerfile is located in the current directory.

## Running the Script

The script requires a directory containing the audio files to be merged. The files should be named sequentially (e.g., `01_chapter.mp3`, `02_chapter.mp3`, `03_chapter.mp3`, ...). The script automatically detects the sequential order based on the filenames.

To run the script:

```shell
./merge_audiobook.sh audiobook_directory/
# or simply point it to a set of files
./merge_audiobook.sh *.m4b
```

Running it from a container should be the same

```bash
docker run merge_audiobook *.m4b
```
