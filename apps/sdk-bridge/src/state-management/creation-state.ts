import { mkdir, readFile, writeFile } from 'fs/promises';
import { join } from 'path';
import { randomUUID } from 'crypto';
import type { ProjectInfo, ProjectCreation, CreationProgress } from '../types.js';
import { CreationStatus } from '../types.js';

export { CreationStatus };

interface PersistedCreation {
  id: string;
  name: string;
  path: string;
  description: string;
  status: string;
  sessionId?: string;
  progress?: CreationProgress;
  error?: string;
  createdAt: string;
  completedAt?: string;
}

export class CreationStateManager {
  private creations: Map<string, ProjectCreation> = new Map();
  private stateDir: string;

  constructor(stateDir?: string) {
    this.stateDir = stateDir || join(process.env.HOME || '~', '.capacitor');
  }

  startCreation(projectInfo: ProjectInfo): ProjectCreation {
    const creation: ProjectCreation = {
      id: randomUUID(),
      name: projectInfo.name,
      path: projectInfo.path,
      description: projectInfo.description,
      status: CreationStatus.Pending,
      createdAt: new Date(),
    };

    this.creations.set(creation.id, creation);
    return creation;
  }

  getCreation(id: string): ProjectCreation | undefined {
    return this.creations.get(id);
  }

  markInProgress(id: string, sessionId: string): void {
    const creation = this.creations.get(id);
    if (creation) {
      creation.status = CreationStatus.InProgress;
      creation.sessionId = sessionId;
    }
  }

  markCompleted(id: string): void {
    const creation = this.creations.get(id);
    if (creation) {
      creation.status = CreationStatus.Completed;
      creation.completedAt = new Date();
    }
  }

  markFailed(id: string, error: string): void {
    const creation = this.creations.get(id);
    if (creation) {
      creation.status = CreationStatus.Failed;
      creation.error = error;
    }
  }

  getActiveCreations(): ProjectCreation[] {
    return Array.from(this.creations.values()).filter(
      c => c.status === CreationStatus.Pending || c.status === CreationStatus.InProgress
    );
  }

  updateProgress(id: string, progress: CreationProgress): void {
    const creation = this.creations.get(id);
    if (creation) {
      creation.progress = progress;
    }
  }

  async persist(): Promise<void> {
    await mkdir(this.stateDir, { recursive: true });
    const statePath = join(this.stateDir, 'creations.json');

    const data: PersistedCreation[] = Array.from(this.creations.values()).map(c => ({
      id: c.id,
      name: c.name,
      path: c.path,
      description: c.description,
      status: c.status,
      sessionId: c.sessionId,
      progress: c.progress,
      error: c.error,
      createdAt: c.createdAt.toISOString(),
      completedAt: c.completedAt?.toISOString(),
    }));

    await writeFile(statePath, JSON.stringify(data, null, 2));
  }

  async load(): Promise<void> {
    const statePath = join(this.stateDir, 'creations.json');

    try {
      const content = await readFile(statePath, 'utf-8');
      const data: PersistedCreation[] = JSON.parse(content);

      this.creations.clear();
      for (const item of data) {
        const creation: ProjectCreation = {
          id: item.id,
          name: item.name,
          path: item.path,
          description: item.description,
          status: item.status as CreationStatus,
          sessionId: item.sessionId,
          progress: item.progress,
          error: item.error,
          createdAt: new Date(item.createdAt),
          completedAt: item.completedAt ? new Date(item.completedAt) : undefined,
        };
        this.creations.set(creation.id, creation);
      }
    } catch {
      // File doesn't exist or is invalid - start fresh
    }
  }
}
