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

### Sparkle 2.10.1

- Source: https://github.com/sparkle-project/Sparkle (tag `2.10.1`, commit `ab7d71291238df6e0492143b120c9b696a35f603`)
- License: MIT License, with the bundled components under the licenses listed in its LICENSE file below.
- Linked as `Sparkle.framework` to check for and install updates.

```text
Copyright (c) 2006-2013 Andy Matuschak.
Copyright (c) 2009-2013 Elgato Systems GmbH.
Copyright (c) 2011-2014 Kornel Lesiński.
Copyright (c) 2015-2017 Mayur Pawashe.
Copyright (c) 2014 C.W. Betts.
Copyright (c) 2014 Petroules Corporation.
Copyright (c) 2014 Big Nerd Ranch.
All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

=================
EXTERNAL LICENSES
=================

bspatch.c and bsdiff.c, from bsdiff 4.3 <http://www.daemonology.net/bsdiff/>:

Copyright 2003-2005 Colin Percival
All rights reserved

Redistribution and use in source and binary forms, with or without
modification, are permitted providing that the following conditions 
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

--

sais.c and sais.h, from sais-lite (2010/08/07) <https://sites.google.com/site/yuta256/sais>:

The sais-lite copyright is as follows:

Copyright (c) 2008-2010 Yuta Mori All Rights Reserved.

Permission is hereby granted, free of charge, to any person
obtaining a copy of this software and associated documentation
files (the "Software"), to deal in the Software without
restriction, including without limitation the rights to use,
copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
OTHER DEALINGS IN THE SOFTWARE.

--

Portable C implementation of Ed25519, from https://github.com/orlp/ed25519

Copyright (c) 2015 Orson Peters <orsonpeters@gmail.com>

This software is provided 'as-is', without any express or implied warranty. In no event will the
authors be held liable for any damages arising from the use of this software.

Permission is granted to anyone to use this software for any purpose, including commercial
applications, and to alter it and redistribute it freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not claim that you wrote the
   original software. If you use this software in a product, an acknowledgment in the product
   documentation would be appreciated but is not required.

2. Altered source versions must be plainly marked as such, and must not be misrepresented as
   being the original software.

3. This notice may not be removed or altered from any source distribution.

--

SUSignatureVerifier.m:

Copyright (c) 2011 Mark Hamlin.

All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted providing that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
```

### WhisperKit 1.1.1

- Source: https://github.com/argmaxinc/WhisperKit (tag `v1.1.1`)
- License: MIT License. Copyright Argmax, Inc.
- Runs the on-device transcription model. Its own dependencies (swift-transformers and others, see `Package.resolved`) are under the Apache License 2.0 or the MIT License.

### llama.cpp b11929

- Source: https://github.com/ggml-org/llama.cpp (release `b11929`, prebuilt `llama.xcframework`)
- License: MIT License. Copyright the ggml authors.
- Runs the on-device summary model.

## Models

### Nemotron-3-Diarization (speaker separation)

- Source: https://huggingface.co/FluidInference/nemotron-3-diarization-coreml (Core ML conversion of NVIDIA Nemotron-3-Diarization; the app downloads the `offline` preset)
- License: OpenMDW License 1.1, https://github.com/OpenMDW/OpenMDW
- Original model by NVIDIA. Core ML conversion by Fluid Inference.

### pyannote community-1 with WeSpeaker embeddings (voiceprints)

- Source: https://huggingface.co/FluidInference/speaker-diarization-coreml (revision `df2625ac79a7ac6b65ad868fee6d80f320da4232`), a Core ML conversion of https://huggingface.co/pyannote/speaker-diarization-community-1
- License: Creative Commons Attribution 4.0 International (CC BY 4.0), https://creativecommons.org/licenses/by/4.0/
- Attribution: pyannote (pyannoteAI, Hervé Bredin), the WeSpeaker speaker-embedding model, the PLDA parameters from BUT Speech@FIT (also CC BY 4.0), and Fluid Inference for the Core ML conversion. The app uses the FBank and WeSpeaker embedding models to compute voiceprints. The conversion was not otherwise modified by mm2t.

### Breeze-ASR-25 (on-device transcription, optional download)

- Source: https://huggingface.co/weiren119/Breeze-ASR-25-coreml-4bit-palette (revision `3fc1623`), a community Core ML conversion of https://huggingface.co/MediaTek-Research/Breeze-ASR-25 (tokenizer from revision `cffe7cc`)
- License: Apache License 2.0, https://www.apache.org/licenses/LICENSE-2.0
- Original model by MediaTek Research, fine-tuned from OpenAI Whisper large-v2.

### Qwen3.5-9B (on-device summaries, optional download)

- Source: https://huggingface.co/unsloth/Qwen3.5-9B-GGUF (revision `3885219`, `Q4_K_M` quantization)
- License: Apache License 2.0, https://www.apache.org/licenses/LICENSE-2.0
- Original model by Alibaba Cloud (Qwen team). GGUF quantization by Unsloth.

## Tabler Icons 3.51.0

The interface icons in `App/MM2T/Icons/`. MIT License, Copyright (c) 2020-2026 Paweł Kuna.
Source: https://github.com/tabler/tabler-icons. The license text ships in the app as `TABLER-LICENSE.txt`.
