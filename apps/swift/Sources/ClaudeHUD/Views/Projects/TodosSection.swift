import SwiftUI

struct TodosSection: View {
    let todos: [Todo]
    let fileId: String?
    var onStatusChange: ((String, String, String) -> Void)?
    var onAddTodo: ((String, String) -> Void)?

    @State private var showingAddTodo = false
    @State private var newTodoContent = ""

    init(todos: [Todo], fileId: String? = nil, onStatusChange: ((String, String, String) -> Void)? = nil, onAddTodo: ((String, String) -> Void)? = nil) {
        self.todos = todos
        self.fileId = fileId
        self.onStatusChange = onStatusChange
        self.onAddTodo = onAddTodo
    }

    var body: some View {
        if todos.isEmpty && fileId == nil {
            return AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    DetailSectionLabel(title: "TODOS")
                    Text("No todos recorded")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                }
            )
        }

        let completed = todos.filter { $0.isCompleted }.count
        let inProgress = todos.filter { $0.isInProgress }.count

        return AnyView(
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    DetailSectionLabel(title: "TODOS")
                    Spacer()
                    if fileId != nil {
                        Button {
                            showingAddTodo.toggle()
                        } label: {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.green.opacity(0.7))
                        Text("\(completed)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.orange.opacity(0.7))
                        Text("\(inProgress)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)
                    }

                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.white.opacity(0.3))
                            .frame(width: 6, height: 6)
                        Text("\(todos.count)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(0.6))
                    }

                    Spacer()
                }

                if showingAddTodo {
                    HStack(spacing: 8) {
                        TextField("New todo...", text: $newTodoContent)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.05))
                            .cornerRadius(6)

                        Button {
                            if !newTodoContent.isEmpty, let fileId = fileId {
                                onAddTodo?(fileId, newTodoContent)
                                newTodoContent = ""
                                showingAddTodo = false
                            }
                        } label: {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundColor(.green.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                        .disabled(newTodoContent.isEmpty)

                        Button {
                            newTodoContent = ""
                            showingAddTodo = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundColor(.white.opacity(0.4))
                        }
                        .buttonStyle(.plain)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(todos.prefix(10)) { todo in
                        TodoItem(
                            todo: todo,
                            onStatusChange: fileId != nil ? { newStatus in
                                onStatusChange?(fileId!, todo.id, newStatus)
                            } : nil
                        )
                    }

                    if todos.count > 10 {
                        Text("+\(todos.count - 10) more")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
            }
        )
    }
}

struct TodoItem: View {
    let todo: Todo
    var onStatusChange: ((String) -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                if let onStatusChange = onStatusChange {
                    if todo.isCompleted {
                        onStatusChange("pending")
                    } else {
                        onStatusChange("completed")
                    }
                }
            } label: {
                if todo.isCompleted {
                    Image(systemName: "checkmark.square.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.green.opacity(0.7))
                } else if todo.isInProgress {
                    Image(systemName: "play.square.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.orange.opacity(0.7))
                } else {
                    Image(systemName: "square")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.4))
                }
            }
            .buttonStyle(.plain)
            .disabled(onStatusChange == nil)

            Text(todo.content)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(todo.isCompleted ? 0.4 : 0.7))
                .strikethrough(todo.isCompleted)
                .lineLimit(2)

            Spacer()

            if onStatusChange != nil && !todo.isCompleted && !todo.isInProgress {
                Menu {
                    Button {
                        onStatusChange?("in_progress")
                    } label: {
                        Label("Start", systemImage: "play.fill")
                    }
                    Button {
                        onStatusChange?("completed")
                    } label: {
                        Label("Complete", systemImage: "checkmark")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.3))
                }
                .menuStyle(.borderlessButton)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
