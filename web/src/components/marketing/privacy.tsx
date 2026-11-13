"use client";
import Image from "next/image";
import { useCopy } from "@/components/i18n";
import { Icon } from "@/components/icon";
import {
  Reveal,
  REPO,
  container,
  sectionPadding,
  heading,
  label,
  textLink,
} from "./shared";
export function Privacy() {
  const { t } = useCopy();
  return (
    <section
      id="privacy"
      className={`${sectionPadding} bg-[#1b1b1d] text-background`}
      aria-labelledby="privacy-title"
    >
      <div
        className={`${container} grid items-center gap-16 lg:grid-cols-2 lg:gap-24`}
      >
        <Reveal>
          <span className={`${label} text-[#e7a06b]`}>
            {t("資料的去向，由你決定")}
          </span>
          <h2 id="privacy-title" className={heading}>
            {t("你的會議，")}
            <br />
            {t("留在你的 Mac。")}
          </h2>
          <p className="mt-7 text-sm leading-8 text-background/60">
            {t("錄音、聲紋與會議紀錄儲存在本機。")}
            <br />
            {t("mm2t 沒有自己的伺服器，也不代管你的資料。")}
          </p>
          <div className="my-8 grid gap-4 text-sm text-background/80">
            <div className="flex items-center gap-3">
              <Icon name="lock" />
              {t("API 金鑰存放於 macOS 鑰匙圈")}
            </div>
            <div className="flex items-center gap-3">
              <Icon name="shield" />
              {t("聲紋辨識在 Mac 本機完成")}
            </div>
          </div>
          <a
            className={textLink}
            href={`${REPO}/blob/main/PRIVACY.md`}
            target="_blank"
            rel="noreferrer"
          >
            {t("閱讀隱私權政策")}
            <Icon name="diagonal" size={17} />
          </a>
        </Reveal>
        <Reveal>
          <div className="mx-auto w-72 rounded-[28px] border border-white/10 bg-[#28282a] p-5 shadow-[0_24px_50px_#0002]">
            <div className="flex items-center justify-between text-xs text-background/60">
              <span>{t("你的 Mac")}</span>
              <Icon name="lock" size={18} />
            </div>
            <Image
              src="/media/icon.png"
              alt="mm2t"
              width={78}
              height={78}
              className="mx-auto my-7 rounded-2xl"
            />
            <div className="flex justify-around text-xs text-background/80">
              {[
                { icon: "mic", label: "錄音" },
                { icon: "users", label: "聲紋" },
                { icon: "file", label: "紀錄" },
              ].map((item) => (
                <span
                  key={item.icon}
                  className="flex flex-col items-center gap-2"
                >
                  <Icon name={item.icon as "mic" | "users" | "file"} />
                  {t(item.label)}
                </span>
              ))}
            </div>
            <div className="mt-6 flex items-center justify-center gap-2 border-t border-white/10 pt-4 text-xs text-background/50">
              <span className="size-1.5 rounded-full bg-[#9da87d]" />
              {t("保存在本機")}
            </div>
          </div>
          <div className="mx-auto h-12 w-px bg-white/15" aria-hidden="true" />
          <div className="grid grid-cols-2 gap-3">
            <div className="flex flex-col items-center gap-3 rounded-2xl border border-white/10 p-5 text-center">
              <Icon name="cloud" size={22} />
              <strong className="text-sm font-medium">
                {t("你選擇的 API")}
              </strong>
              <span className="text-xs leading-6 text-background/50">
                {t("使用自己的金鑰")}
                <br />
                {t("直接連線至服務商")}
              </span>
            </div>
            <div className="flex flex-col items-center gap-3 rounded-2xl border border-white/10 p-5 text-center">
              <Icon name="laptop" size={22} />
              <strong className="text-sm font-medium">
                {t("自架轉錄伺服器")}
              </strong>
              <span className="text-xs leading-6 text-background/50">
                {t("音訊在自己的")}
                <br />
                {t("設備之間傳輸")}
              </span>
            </div>
          </div>
          <p className="mt-5 text-xs leading-6 text-background/45">
            {t(
              "選用雲端服務時，音訊或文字會傳送至所選服務商處理；費用由你的 API 帳號支付。",
            )}
          </p>
        </Reveal>
      </div>
    </section>
  );
}
