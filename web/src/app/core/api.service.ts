import { HttpClient, HttpErrorResponse } from '@angular/common/http';
import { Injectable } from '@angular/core';
import { Observable, throwError } from 'rxjs';
import { catchError } from 'rxjs/operators';

import { ErrorService } from './error.service';
import { ApiError } from './models';

export interface ApiRequestOptions {
  broadcastError?: boolean;
}

@Injectable({ providedIn: 'root' })
export class ApiService {
  constructor(
    private readonly http: HttpClient,
    private readonly errorService: ErrorService,
  ) {}

  get<T>(path: string, options: ApiRequestOptions = {}): Observable<T> {
    return this.http.get<T>(path).pipe(catchError((err) => this.handleError(err, options)));
  }

  post<T>(path: string, body: unknown, options: ApiRequestOptions = {}): Observable<T> {
    return this.http.post<T>(path, body).pipe(catchError((err) => this.handleError(err, options)));
  }

  private handleError(err: HttpErrorResponse, options: ApiRequestOptions): Observable<never> {
    const apiError = this.toApiError(err);
    if (options.broadcastError !== false) {
      this.errorService.show(apiError);
    }
    return throwError(() => apiError);
  }

  private toApiError(err: HttpErrorResponse): ApiError {
    const body = err.error;
    if (body && typeof body === 'object' && typeof body.code === 'string' && typeof body.message === 'string') {
      return { status: err.status, code: body.code, message: body.message };
    }
    return { status: err.status || 0, code: 'internal', message: err.message || 'Request failed' };
  }
}