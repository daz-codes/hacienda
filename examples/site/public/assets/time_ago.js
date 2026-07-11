export const time_ago_in_words = seconds => {
  const elapsed = Math.max(0, Number(seconds) || 0);
  const minutes = Math.floor(elapsed / 60);

  return minutes > 0
    ? `${minutes} minute${minutes === 1 ? "" : "s"} ago`
    : "Just now";
};

export const start_time_ago_clock = (state, interval = 10_000) => {
  state.timestamp = Date.now() / 1000;

  const timer = setInterval(() => {
    state.timestamp = Date.now() / 1000;
  }, interval);

  return () => clearInterval(timer);
};
