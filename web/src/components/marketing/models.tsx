"use client";
import { useCopy } from "@/components/i18n";
import { Icon, type IconName } from "@/components/icon";
import { cn } from "@/lib/utils";
import { wrap } from "./shared";

const breeze = { name: "Breeze-ASR-25", source: "https://huggingface.co/MediaTek-Research/Breeze-ASR-25", languages: "台灣華語、中英夾雜" };
const nemotron = { name: "Nemotron 3.5 Multilingual", source: "https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b", languages: "華語、英語、日語、韓語等" };
const scribe = { source: "https://elevenlabs.io/docs/overview/models", languages: "華語、英語、法語等 90 多種語言" };

const parakeet = { name: "Parakeet TDT v3", source: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3", languages: "英、法、德、西語等 25 種歐洲語言" };

type Model = {
  name: string;
  source: string;
  languages: string;
  use: string;
  runtime: string;
};

type ModelGroup = {
  id: string;
  title: string;
  icon: IconName;
  intro: string;
  models: Model[];
};

const groups: ModelGroup[] = [
  {
    id: "live", title: "即時語音與字幕", icon: "mic",
    intro: "全英文會議首選 Parakeet。有華語發言，又想讓字幕跟上對話，首選 Nemotron。",
    models: [
      { ...parakeet, runtime: "Mac · Core ML", use: "辨識速度很快，適合全英文會議，也適合使用法語、德語等歐洲語言的場合。" },
      { ...nemotron, runtime: "Mac · Core ML", use: "華語和英語都能快速出字，適合需要一邊看字幕、一邊跟上討論的人。" },
      { ...breeze, runtime: "Mac · Core ML / MLX", use: "擅長辨識台灣華語裡穿插的英文術語，但出字很慢，字幕容易落在發言後面。較適合會後轉錄。" },
      { ...scribe, name: "Scribe v3 Live", runtime: "ElevenLabs · API", use: "需要多語即時字幕，並希望由雲端處理語音。" },
    ],
  },
  {
    id: "translation", title: "即時字幕翻譯", icon: "messages",
    intro: "首選 Apple Translation，其次是 Hy-MT2。Bergamot 可作為備選。",
    models: [
      { name: "Apple Translation", source: "https://developer.apple.com/documentation/translation", languages: "繁中與英文互譯，也可選已安裝的目標語言",
        runtime: "Mac · macOS 26+", use: "我們測過的會議短句翻得快，也能準確傳達原意。Mac 已安裝所需語言包時，優先選它。" },
      { name: "Hy-MT2-1.8B", source: "https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF", languages: "繁中或英文可直譯成法、西、越、捷文等",
        runtime: "Mac · GGUF Q4_K_M", use: "翻譯準確，遇到會議術語也有不錯的表現。譯文會比原文字幕晚一點出現。" },
      { name: "Bergamot", source: "https://github.com/browsermt/bergamot-translator", languages: "繁中與英文互譯，也可譯成日、韓、德、捷文等",
        runtime: "Mac · Firefox Translations", use: "翻得快，但在我們測過的會議短句中較容易譯錯細節，適合用來掌握大意。" },
    ],
  },
  { id: "transcription", title: "會後轉錄", icon: "file", intro: "想盡快拿到逐字稿，或想保留中英夾雜的用字，可以依錄音內容來選。", models: [
    { ...parakeet, runtime: "Mac · Core ML", use: "全英文或其他支援的歐洲語言錄音，首選 Parakeet，很快就能拿到逐字稿。" },
    { ...nemotron, runtime: "Mac · Core ML", use: "想快速整理有華語發言的錄音，或同一場會議裡有人說中文、有人說英文，可優先選它。" },
    { ...breeze, runtime: "Mac · Core ML / MLX", use: "台灣華語裡夾雜英文人名、產品名或術語時，Breeze 較能保留原話。轉錄較慢，適合願意等完整逐字稿的人。" },
    { name: "Whisper Base (CPU)", source: "https://github.com/openai/whisper", languages: "華語、英語、日語等多種語言", runtime: "Mac · CPU", use: "使用 Intel Mac，或透過 Rosetta 執行 App 時的本機選擇。" },
    { ...scribe, name: "Scribe v2", runtime: "ElevenLabs · API", use: "需要雲端逐字稿、說話者標籤與逐字時間戳記。" },
  ] },
  { id: "llm", title: "地端大語言模型", icon: "sparkles", intro: "逐字稿完成後，由 Mac 在本機整理。建議使用配備 16 GB 以上記憶體的 Apple 晶片 Mac。", models: [
    { name: "Qwen3.5-9B", source: "https://huggingface.co/Qwen/Qwen3.5-9B", languages: "繁體中文、英文等", runtime: "Mac · GGUF Q4_K_M", use: "從逐字稿整理重點與待辦，保留英文術語。模型下載約 5.7 GB。" },
  ] },
];

function ModelName({ model }: { model: Model }) {
  return (
    <a href={model.source} className="inline-flex min-h-9 items-center gap-1.5 font-medium hover:underline">
      {model.name}<Icon name="diagonal" size={13} className="shrink-0 text-muted-foreground" />
    </a>
  );
}

export function ModelGuide() {
  const { t } = useCopy();
  return (
    <div className={cn(wrap, "grid gap-8 border-t border-border pt-6 pb-16 lg:grid-cols-[13rem_1fr] lg:gap-10 lg:pt-9")}>
      <nav aria-label={t("依用途瀏覽模型")} className="flex flex-wrap content-start gap-x-4 lg:sticky lg:top-24 lg:block lg:self-start">
        {groups.map(group => (
          <a key={group.id} href={"#" + group.id} className="link-draw flex min-h-11 items-center gap-2 text-sm">
            <Icon name={group.icon} size={16} />{t(group.title)}
          </a>
        ))}
      </nav>
      <div className="min-w-0 space-y-12">
        {groups.map(group => (
          <section key={group.id} id={group.id} aria-labelledby={group.id + "-title"} className="scroll-mt-24">
            <h2 id={group.id + "-title"} className="text-2xl font-medium tracking-tight md:text-3xl">{t(group.title)}</h2>
            <p className="mt-2 mb-5 text-sm leading-relaxed text-muted-foreground">{t(group.intro)}</p>
            <div className="grid divide-y divide-border border-y border-border">
              {group.models.map(model => (
                <article key={model.name} className="grid gap-2 py-4 sm:grid-cols-[minmax(0,1fr)_minmax(0,1.2fr)] sm:gap-6">
                  <div>
                    <h3><ModelName model={model} /></h3>
                    <p className="font-mono text-xs text-muted-foreground">{model.runtime}</p>
                  </div>
                  <div>
                    <p className="text-sm leading-7 font-medium">{t(model.languages)}</p>
                    <p className="mt-1 text-sm leading-relaxed text-muted-foreground">{t(model.use)}</p>
                  </div>
                </article>
              ))}
            </div>
          </section>
        ))}
      </div>
    </div>
  );
}
