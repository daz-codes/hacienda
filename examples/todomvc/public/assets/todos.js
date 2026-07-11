export function visibleTodos(todos, filter) {
  if (filter === "active") return todos.filter((todo) => !todo.completed);
  if (filter === "completed") return todos.filter((todo) => todo.completed);
  return todos;
}

export function todoCompleted(id, todos) {
  return todos.find((todo) => todo.id === id)?.completed || false;
}

export function todoTitle(id, todos) {
  return todos.find((todo) => todo.id === id)?.title || "";
}

export function toggleLocal(todos, id) {
  const todo = todos.find((item) => item.id === id);
  if (todo) todo.completed = !todo.completed;
}

export function removeLocal(todos, id) {
  const index = todos.findIndex((todo) => todo.id === id);
  if (index >= 0) todos.splice(index, 1);
}

export function renameLocal(todos, id, title) {
  const todo = todos.find((item) => item.id === id);
  if (todo) todo.title = title.trim();
}
