import { Routes } from '@angular/router';

export const routes: Routes = [
  {
    path: '',
    pathMatch: 'full',
    loadComponent: () => import('./dashboard/dashboard.component').then((m) => m.DashboardComponent),
  },
  {
    path: 'process/:processInstanceKey',
    loadComponent: () => import('./process-detail/process-detail.component').then((m) => m.ProcessDetailComponent),
  },
  {
    path: 'tasks',
    loadComponent: () => import('./tasks/task-list.component').then((m) => m.TaskListComponent),
  },
  { path: '**', redirectTo: '' },
];