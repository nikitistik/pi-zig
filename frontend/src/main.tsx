import { render } from 'preact';
import { App } from './App';
import { StoreContext } from './hooks';
import { WorkbenchStore } from './store';
import './styles.css';

const store = new WorkbenchStore();

render(
  <StoreContext.Provider value={store}>
    <App />
  </StoreContext.Provider>,
  document.getElementById('app')!,
);
