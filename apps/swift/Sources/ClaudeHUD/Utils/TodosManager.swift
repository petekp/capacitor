import Foundation
import Combine

struct Todo: Codable, Identifiable {
    var id: String
    var content: String
    var status: String
    var activeForm: String?
    var priority: String?

    var isCompleted: Bool {
        status == "completed"
    }

    var isInProgress: Bool {
        status == "in_progress"
    }

    var isPending: Bool {
        status == "pending"
    }
}

struct TodoFileEntry: Identifiable {
    let id: String
    let filename: String
    var todos: [Todo]
}

class TodosManager: ObservableObject {
    @Published var todos: [String: [Todo]] = [:]
    @Published var todoFiles: [String: TodoFileEntry] = [:]

    private let fileManager = FileManager.default
    private let todosDirectory = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/todos")

    func loadTodos() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            var projectTodos: [String: [Todo]] = [:]
            var files: [String: TodoFileEntry] = [:]

            do {
                let fileList = try self.fileManager.contentsOfDirectory(atPath: self.todosDirectory)

                for file in fileList where file.hasSuffix(".json") {
                    let filePath = (self.todosDirectory as NSString).appendingPathComponent(file)

                    if let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) {
                        if let todoArray = try? JSONDecoder().decode([Todo].self, from: data) {
                            if !todoArray.isEmpty {
                                let projectId = file.replacingOccurrences(of: ".json", with: "")
                                projectTodos[projectId] = todoArray
                                files[projectId] = TodoFileEntry(id: projectId, filename: file, todos: todoArray)
                            }
                        }
                    }
                }

                DispatchQueue.main.async {
                    self.todos = projectTodos
                    self.todoFiles = files
                }
            } catch {
                print("Failed to load todos: \(error)")
            }
        }
    }

    func getTodos(for projectPath: String) -> [Todo] {
        for (key, todos) in self.todos {
            if projectPath.contains(key) || key.contains(projectPath) {
                return todos
            }
        }
        return []
    }

    func getFileId(for projectPath: String) -> String? {
        for (key, _) in self.todos {
            if projectPath.contains(key) || key.contains(projectPath) {
                return key
            }
        }
        return nil
    }

    func getCompletionStatus(for projectPath: String) -> (completed: Int, total: Int) {
        let todos = getTodos(for: projectPath)
        let completed = todos.filter { $0.isCompleted }.count
        return (completed, todos.count)
    }

    func updateTodoStatus(fileId: String, todoId: String, newStatus: String) {
        guard var fileEntry = todoFiles[fileId],
              let todoIndex = fileEntry.todos.firstIndex(where: { $0.id == todoId }) else {
            return
        }

        fileEntry.todos[todoIndex].status = newStatus

        todoFiles[fileId] = fileEntry
        todos[fileId] = fileEntry.todos

        saveTodoFile(fileEntry)
    }

    func addTodo(fileId: String, content: String) {
        guard var fileEntry = todoFiles[fileId] else {
            return
        }

        let newId = String(UUID().uuidString.prefix(8))
        let newTodo = Todo(id: newId, content: content, status: "pending", activeForm: nil, priority: nil)

        fileEntry.todos.append(newTodo)

        todoFiles[fileId] = fileEntry
        todos[fileId] = fileEntry.todos

        saveTodoFile(fileEntry)
    }

    func createTodoFile(withTodo content: String) -> String {
        let fileId = UUID().uuidString
        let filename = "\(fileId)-agent-\(fileId).json"

        let newTodo = Todo(id: "1", content: content, status: "pending", activeForm: nil, priority: nil)
        let fileEntry = TodoFileEntry(id: fileId, filename: filename, todos: [newTodo])

        todoFiles[fileId] = fileEntry
        todos[fileId] = [newTodo]

        saveTodoFile(fileEntry)
        return fileId
    }

    private func saveTodoFile(_ entry: TodoFileEntry) {
        let filePath = (todosDirectory as NSString).appendingPathComponent(entry.filename)

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(entry.todos)
            try data.write(to: URL(fileURLWithPath: filePath))
        } catch {
            print("Failed to save todo file: \(error)")
        }
    }

    func getAllTodoFiles() -> [TodoFileEntry] {
        return Array(todoFiles.values).filter { !$0.todos.isEmpty }
            .sorted { ($0.todos.first(where: { $0.isInProgress }) != nil ? 0 : 1) < ($1.todos.first(where: { $0.isInProgress }) != nil ? 0 : 1) }
    }
}
