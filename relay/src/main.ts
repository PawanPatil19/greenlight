import { createRelay } from "./server.js";

const port = Number(process.env.PORT ?? 8787);

createRelay().listen(port, () => {
  console.log(`greenlight relay listening on http://localhost:${port}`);
});
