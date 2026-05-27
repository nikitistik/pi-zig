/** Preact integration for the WorkbenchStore. */

import { createContext } from 'preact';
import { useContext, useEffect, useReducer } from 'preact/hooks';
import type { WorkbenchState, WorkbenchStore } from './store';

export const StoreContext = createContext<WorkbenchStore | null>(null);

export function useStore(): WorkbenchStore {
  const store = useContext(StoreContext);
  if (!store) throw new Error('StoreContext is not provided');
  return store;
}

/** Subscribe a component to the store and re-render on every change. */
export function useWorkbenchState(): WorkbenchState {
  const store = useStore();
  const [, forceRender] = useReducer((tick: number, _action: void) => tick + 1, 0);
  useEffect(() => store.subscribe(() => forceRender()), [store]);
  return store.getState();
}

/**
 * Read a File (image) into the backend ImageContent shape (base64 + mimeType).
 */
export function fileToImageContent(file: File): Promise<{ type: 'image'; data: string; mimeType: string }> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onerror = () => reject(reader.error ?? new Error('Failed to read file'));
    reader.onload = () => {
      const result = typeof reader.result === 'string' ? reader.result : '';
      const comma = result.indexOf(',');
      const data = comma >= 0 ? result.slice(comma + 1) : result;
      resolve({ type: 'image', data, mimeType: file.type || 'application/octet-stream' });
    };
    reader.readAsDataURL(file);
  });
}
