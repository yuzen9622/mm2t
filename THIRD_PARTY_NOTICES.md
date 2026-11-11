# Third-party notices

mm2t separates speakers on the Mac with the software and models below. The SDK is linked into the app. The models are not shipped with the app; it downloads them from Hugging Face on first use into `~/Library/Application Support/mm2t/Models`.

## Software

### FluidAudio 0.18.3

- Source: https://github.com/FluidInference/FluidAudio (tag `0.18.3`, commit `c8b41f98eae668794dd0083bbe028fe7e6585051`)
- License: Apache License 2.0, https://www.apache.org/licenses/LICENSE-2.0
- Copyright Fluid Inference.
- Linked with only its `Diarizer` trait. The NeMo text-processing binary and the text-to-speech code are not part of the app.

FluidAudio includes these components, which the app links:

- **fastcluster** (hierarchical clustering). Copyright 2011 Daniel Müllner (until 1.1.23) and Google Inc. (from 1.1.24). BSD 2-Clause License:

  > Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:
  >
  > - Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
  > - Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
  >
  > THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

- **VBx** clustering (BUT Speech@FIT). Apache License 2.0, https://github.com/BUTSpeechFIT/VBx

## Models

### Nemotron-3-Diarization (speaker separation)

- Source: https://huggingface.co/FluidInference/nemotron-3-diarization-coreml (Core ML conversion of NVIDIA Nemotron-3-Diarization; the app downloads the `offline` preset)
- License: OpenMDW License 1.1, https://github.com/OpenMDW/OpenMDW
- Original model by NVIDIA. Core ML conversion by Fluid Inference.

### pyannote community-1 with WeSpeaker embeddings (voiceprints)

- Source: https://huggingface.co/FluidInference/speaker-diarization-coreml (revision `df2625ac79a7ac6b65ad868fee6d80f320da4232`), a Core ML conversion of https://huggingface.co/pyannote/speaker-diarization-community-1
- License: Creative Commons Attribution 4.0 International (CC BY 4.0), https://creativecommons.org/licenses/by/4.0/
- Attribution: pyannote (pyannoteAI, Hervé Bredin), the WeSpeaker speaker-embedding model, the PLDA parameters from BUT Speech@FIT (also CC BY 4.0), and Fluid Inference for the Core ML conversion. The app uses the FBank and WeSpeaker embedding models to compute voiceprints. The conversion was not otherwise modified by mm2t.
