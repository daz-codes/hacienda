export function formatDuration(value) {
  const minutes = Number(value)
  const hours = Math.floor(minutes / 60)
  const remainder = minutes % 60

  if (hours === 0) return `${minutes} min`
  return remainder === 0 ? `${hours}h` : `${hours}h ${remainder}m`
}
