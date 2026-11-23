import { AccountAPIError } from "./api";

type Paddle = {
  Environment: { set: (environment: "sandbox") => void };
  Initialize: (options: { token: string; eventCallback: (event: { name: string }) => void }) => void;
  Checkout: { open: (options: { transactionId: string }) => void };
};

let ready: Promise<Paddle> | undefined;
let onCompleted: (() => void) | undefined;

export function loadPaddle(): Promise<Paddle> {
  const token = process.env.NEXT_PUBLIC_PADDLE_CLIENT_TOKEN;
  if (!token) throw new AccountAPIError(503, "billing_unavailable");
  if (ready) return ready;
  ready = new Promise<Paddle>((resolve, reject) => {
    const script = document.createElement("script");
    script.src = "https://cdn.paddle.com/paddle/v2/paddle.js";
    script.async = true;
    script.referrerPolicy = "no-referrer";
    script.onload = () => {
      try {
        const paddle = (window as Window & { Paddle?: Paddle }).Paddle;
        if (!paddle) throw new Error("Paddle.js did not initialize");
        if (process.env.NEXT_PUBLIC_PADDLE_ENV !== "production") paddle.Environment.set("sandbox");
        paddle.Initialize({ token, eventCallback: ({ name }) => {
          if (name === "checkout.completed") {
            const callback = onCompleted;
            onCompleted = undefined;
            callback?.();
          }
        } });
        resolve(paddle);
      } catch (error) { reject(error); }
    };
    script.onerror = () => reject(new Error("Paddle.js did not load"));
    document.head.append(script);
  }).catch((error: unknown) => { ready = undefined; throw error; });
  return ready;
}

export function openCheckout(paddle: Paddle, transactionId: string, completed: () => void) {
  onCompleted = completed;
  paddle.Checkout.open({ transactionId });
}
