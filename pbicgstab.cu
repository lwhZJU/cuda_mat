/*
 * Copyright 1993-2015 NVIDIA Corporation.  All rights reserved.
 *
 * Please refer to the NVIDIA end user license agreement (EULA) associated
 * with this source code for terms and conditions that govern your use of
 * this software. Any use, reproduction, disclosure, or distribution of
 * this software and related documentation outside the terms of the EULA
 * is strictly prohibited.
 *
 */

#include <typeinfo> // for usage of C++ typeid
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <cuda_runtime.h>
#include <vector>
#include <conio.h>
#include <sstream>
#include <iostream>

#include "cublas_v2.h"
#include "cusparse_v2.h"
#include "helper_cusolver.h"
#include "mmio.h"

#include "mmio_wrapper.h"

#include "helper_cuda.h"
#include "pbicgstab.h"


#include <device_launch_parameters.h>

__global__ void mult_spec(int n, double *a, double*b, double k, double *c){
    int i = threadIdx.x + blockIdx.x * blockDim.x;

    if(i >= n) return;

    c[i] = a[i] * b[i] * k;
}



static bool gpu_pbicgstab2(
        cublasHandle_t cublasHandle,
        cusparseHandle_t cusparseHandle,
        int n,
        int nnz,
        const cusparseMatDescr_t descrA,
	    double *A,
        int *iA,
        int *jA,
        double* x0,
        double* b,

        int maxit,
        double tol,
        bool debug,

        double* x, //out

        /*work, all zeroed*/
        double* r0,
        double* r,
        double* r_,
        double* v,
        double* v_,
        double* p,
        double* p_,
        double* s,
        double* t,
        double* h){


	//v = v_ = p = p_ = [0,0,0....0]
	double omega = 1;
	double alpha = 1;
	double beta = 0;
	double rho = 1;
	double rho_ = rho;

	double norm0;

	double one = 1;
	double mone = -1.0;
	double zero = 0;

	checkCudaErrors(cusparseDcsrmv(cusparseHandle, CUSPARSE_OPERATION_NON_TRANSPOSE, n, n, nnz, &mone, descrA, A, iA, jA, x0, &zero, r));

   /* double r_host[3];
    cudaMemcpy(r_host, r, 3 * sizeof(double), cudaMemcpyDeviceToHost);
    std::ostringstream st;
    dump_vector(st, 3, r_host);
    std::cout << st.str() << std::endl;

    checkCudaErrors(cublasDaxpy(cublasHandle, n, &one, b, 1, r, 1));
	checkCudaErrors(cudaMemcpy(r0, r, sizeof(double) * n, cudaMemcpyDeviceToDevice));*/


	checkCudaErrors(cublasDnrm2(cublasHandle, n, r, 1, &norm0));


	if(debug){
        std::cout << "initial norm = " << norm0 << std::endl;
	}

	for(size_t i = 0; i < maxit; i++)
	{

        checkCudaErrors(cublasDdot(cublasHandle, n, r0, 1, r, 1, &rho_));
        beta = (rho_ / rho) * (alpha / omega);
        double momega = -omega;
        checkCudaErrors(cudaMemcpy(p_, v, sizeof(double) * n, cudaMemcpyDeviceToDevice));
        checkCudaErrors(cublasDscal(cublasHandle, n, &momega, p_, 1));
        checkCudaErrors(cublasDaxpy(cublasHandle,n, &one, p, 1, p_, 1));
        checkCudaErrors(cublasDscal(cublasHandle, n, &beta, p_, 1));
        checkCudaErrors(cublasDaxpy(cublasHandle,n, &one, r, 1, p_, 1));


		checkCudaErrors(cusparseDcsrmv(cusparseHandle, CUSPARSE_OPERATION_NON_TRANSPOSE, n, n, nnz, &one, descrA, A, iA, jA, p_, &zero, v_));

       /* double *temp = static_cast<double *>(malloc(sizeof(double) * n));
        cudaMemcpy(temp, v_, sizeof(double)*n, cudaMemcpyDeviceToHost);
        std::cout << "temp" << std::endl;

        std::ostringstream ss;
        dump_vector(ss, n, temp);
        std::cout << ss.str() << std::endl;*/

		double dot_r_v;

		checkCudaErrors(cublasDdot(cublasHandle, n, r0, 1, v_, 1, &dot_r_v));
		alpha = rho_ / dot_r_v;
		double malpha = -alpha;

		//std::cout << "alpha=" << alpha << std::endl;

        checkCudaErrors(cudaMemcpy(h, p_, sizeof(double) * n, cudaMemcpyDeviceToDevice));
        checkCudaErrors(cublasDscal(cublasHandle, n, &alpha, h, 1));
		checkCudaErrors(cublasDaxpy(cublasHandle,n, &one, x0, 1, h, 1));

		checkCudaErrors(cudaMemcpy(s, v_, sizeof(double) * n, cudaMemcpyDeviceToDevice));
		checkCudaErrors(cublasDscal(cublasHandle, n, &malpha, s, 1));
        checkCudaErrors(cublasDaxpy(cublasHandle,n, &one, r, 1, s, 1));


		checkCudaErrors(cusparseDcsrmv(cusparseHandle, CUSPARSE_OPERATION_NON_TRANSPOSE, n, n, nnz, &one, descrA, A, iA, jA, s, &zero, t));

		double num;
		double denum;
		checkCudaErrors(cublasDdot(cublasHandle, n, t, 1, s, 1, &num));
		checkCudaErrors(cublasDdot(cublasHandle, n, t, 1, t, 1, &denum));
		omega = num / denum;
		momega = -omega;


        checkCudaErrors(cudaMemcpy(x, s, sizeof(double) * n, cudaMemcpyDeviceToDevice));
        checkCudaErrors(cublasDscal(cublasHandle, n, &omega, x, 1));
		checkCudaErrors(cublasDaxpy(cublasHandle,n, &one, h, 1, x, 1));

        checkCudaErrors(cudaMemcpy(r_, t, sizeof(double) * n, cudaMemcpyDeviceToDevice));
        checkCudaErrors(cublasDscal(cublasHandle, n, &momega, r_, 1));
		checkCudaErrors(cublasDaxpy(cublasHandle,n, &one, s, 1, r_, 1));

		double norm;
		checkCudaErrors(cublasDnrm2(cublasHandle, n, r_, 1, &norm));


        if(debug){
            std::cout << "k = " << i << ", norm = " << norm << std::endl;
        }

		if(norm < tol * norm0){
			return true;
		}


		if(abs(omega) < 1e-5 || isnan(omega)){
            if(debug){
                std::cout << "omega is close to zero, cannot continue" << std::endl;
                std::cout << "omega = " << omega << std::endl;
            }

            return false;
        }

		checkCudaErrors(cudaMemcpy(r, r_, sizeof(double) * n, cudaMemcpyDeviceToDevice));
		checkCudaErrors(cudaMemcpy(p, p_, sizeof(double) * n, cudaMemcpyDeviceToDevice));
		checkCudaErrors(cudaMemcpy(v, v_, sizeof(double) * n, cudaMemcpyDeviceToDevice));
		checkCudaErrors(cudaMemcpy(x0, x, sizeof(double) * n, cudaMemcpyDeviceToDevice));
		rho = rho_;
	}

	return false;


}

//TODO stupid code duplication
static bool gpu_pbicgstab2(
        cublasHandle_t cublasHandle,
        cusparseHandle_t cusparseHandle,
        int n,
        int nnz,
        const cusparseMatDescr_t descrA,
        double *A0,
        int *iA0,
        int *jA0,
        double *d,
        double* x0,
        double* b,

        int maxit,
        double tol,
        bool debug,

        double* x, //out

        /*work, all zeroed*/
        double* r0,
        double* r,
        double* r_,
        double* v,
        double* v_,
        double* p,
        double* p_,
        double* s,
        double* t,
        double* h){


    //v = v_ = p = p_ = [0,0,0....0]
    double omega = 1;
    double alpha = 1;
    double beta = 0;
    double rho = 1;
    double rho_ = rho;

    double norm0;

    double one = 1;
    double mone = -1.0;
    double zero = 0;

    const int blockDim = 512;

    int blockCount;
    if(n % blockDim == 0){
        blockCount = n / blockDim;
    }else{
        blockCount = n / blockDim + 1;
    }


    mult_spec<<<blockDim, blockCount>>>(n, x0, d, -1, r);


//    double r_host[3];
//    cudaMemcpy(r_host, r, 3 * sizeof(double), cudaMemcpyDeviceToHost);
//    std::ostringstream st;
//    dump_vector(st, 3, r_host);
//    std::cout << st.str() << std::endl;

    checkCudaErrors(cublasDaxpy(cublasHandle, n, &one, b, 1, r, 1));
    checkCudaErrors(cudaMemcpy(r0, r, sizeof(double) * n, cudaMemcpyDeviceToDevice));

    checkCudaErrors(cusparseDcsrmv(cusparseHandle, CUSPARSE_OPERATION_NON_TRANSPOSE, n, n, nnz, &mone, descrA, A0, iA0, jA0, x0, &one, r));




    checkCudaErrors(cublasDnrm2(cublasHandle, n, r, 1, &norm0));


    if(debug){
        std::cout << "initial norm = " << norm0 << std::endl;
    }

    for(size_t i = 0; i < maxit; i++)
    {

        checkCudaErrors(cublasDdot(cublasHandle, n, r0, 1, r, 1, &rho_));
        beta = (rho_ / rho) * (alpha / omega);
        double momega = -omega;
        checkCudaErrors(cudaMemcpy(p_, v, sizeof(double) * n, cudaMemcpyDeviceToDevice));
        checkCudaErrors(cublasDscal(cublasHandle, n, &momega, p_, 1));
        checkCudaErrors(cublasDaxpy(cublasHandle,n, &one, p, 1, p_, 1));
        checkCudaErrors(cublasDscal(cublasHandle, n, &beta, p_, 1));
        checkCudaErrors(cublasDaxpy(cublasHandle,n, &one, r, 1, p_, 1));


        mult_spec<<<blockDim, blockCount>>>(n, p_, d, 1, v_);
        checkCudaErrors(cusparseDcsrmv(cusparseHandle, CUSPARSE_OPERATION_NON_TRANSPOSE, n, n, nnz, &one, descrA, A0, iA0, jA0, p_, &one, v_));

        /* double *temp = static_cast<double *>(malloc(sizeof(double) * n));
         cudaMemcpy(temp, v_, sizeof(double)*n, cudaMemcpyDeviceToHost);
         std::cout << "temp" << std::endl;

         std::ostringstream ss;
         dump_vector(ss, n, temp);
         std::cout << ss.str() << std::endl;*/

        double dot_r_v;

        checkCudaErrors(cublasDdot(cublasHandle, n, r0, 1, v_, 1, &dot_r_v));
        alpha = rho_ / dot_r_v;
        double malpha = -alpha;

        //std::cout << "alpha=" << alpha << std::endl;

        checkCudaErrors(cudaMemcpy(h, p_, sizeof(double) * n, cudaMemcpyDeviceToDevice));
        checkCudaErrors(cublasDscal(cublasHandle, n, &alpha, h, 1));
        checkCudaErrors(cublasDaxpy(cublasHandle,n, &one, x0, 1, h, 1));

        checkCudaErrors(cudaMemcpy(s, v_, sizeof(double) * n, cudaMemcpyDeviceToDevice));
        checkCudaErrors(cublasDscal(cublasHandle, n, &malpha, s, 1));
        checkCudaErrors(cublasDaxpy(cublasHandle,n, &one, r, 1, s, 1));


        mult_spec<<<blockDim, blockCount>>>(n, s, d, 1, t);
        checkCudaErrors(cusparseDcsrmv(cusparseHandle, CUSPARSE_OPERATION_NON_TRANSPOSE, n, n, nnz, &one, descrA, A0, iA0, jA0, s, &one, t));

        double num;
        double denum;
        checkCudaErrors(cublasDdot(cublasHandle, n, t, 1, s, 1, &num));
        checkCudaErrors(cublasDdot(cublasHandle, n, t, 1, t, 1, &denum));
        omega = num / denum;
        momega = -omega;


        checkCudaErrors(cudaMemcpy(x, s, sizeof(double) * n, cudaMemcpyDeviceToDevice));
        checkCudaErrors(cublasDscal(cublasHandle, n, &omega, x, 1));
        checkCudaErrors(cublasDaxpy(cublasHandle,n, &one, h, 1, x, 1));

        checkCudaErrors(cudaMemcpy(r_, t, sizeof(double) * n, cudaMemcpyDeviceToDevice));
        checkCudaErrors(cublasDscal(cublasHandle, n, &momega, r_, 1));
        checkCudaErrors(cublasDaxpy(cublasHandle,n, &one, s, 1, r_, 1));

        double norm;
        checkCudaErrors(cublasDnrm2(cublasHandle, n, r_, 1, &norm));


        if(debug){
            std::cout << "k = " << i << ", norm = " << norm << std::endl;
        }

        if(norm < tol * norm0){
            return true;
        }


        if(abs(omega) < 1e-5 || isnan(omega)){
            if(debug){
                std::cout << "omega is close to zero, cannot continue" << std::endl;
                std::cout << "omega = " << omega << std::endl;
            }

            return false;
        }

        checkCudaErrors(cudaMemcpy(r, r_, sizeof(double) * n, cudaMemcpyDeviceToDevice));
        checkCudaErrors(cudaMemcpy(p, p_, sizeof(double) * n, cudaMemcpyDeviceToDevice));
        checkCudaErrors(cudaMemcpy(v, v_, sizeof(double) * n, cudaMemcpyDeviceToDevice));
        checkCudaErrors(cudaMemcpy(x0, x, sizeof(double) * n, cudaMemcpyDeviceToDevice));
        rho = rho_;
    }

    return false;


}

bool bicgstab(int n, int nnz, double *A, int *iA, int *jA, double *b, int maxit, double tol, bool debug, double *x, double *dtAlg){


    cublasHandle_t cublasHandle  = nullptr;
    cusparseHandle_t cusparseHandle  = nullptr;
    cusparseMatDescr_t descrA= nullptr;
    cusparseStatus_t status1;
    double *dev_A       = nullptr;
    int    *dev_iA = nullptr;
    int    *dev_jA = nullptr;
    double *dev_x0 = nullptr;
    double *dev_b = nullptr;
    double *dev_x = nullptr;
    double *dev_r0 = nullptr;
    double *dev_r = nullptr;
    double *dev_r_ = nullptr;
    double *dev_v = nullptr;
    double *dev_v_ = nullptr;
    double *dev_p = nullptr;
    double *dev_p_ = nullptr;
    double *dev_s = nullptr;
    double *dev_t = nullptr;
    double *dev_h = nullptr;



    int base = iA[0];

    /* initialize cublas */
    if (cublasCreate(&cublasHandle) != CUBLAS_STATUS_SUCCESS) {
        fprintf( stderr, "!!!! CUBLAS initialization error\n" );
        return false;
    }
    /* initialize cusparse */
    status1 = cusparseCreate(&cusparseHandle);
    if (status1 != CUSPARSE_STATUS_SUCCESS) {
        fprintf( stderr, "!!!! CUSPARSE initialization error\n" );
        return false;
    }
    /* create three matrix descriptors */
    status1 = cusparseCreateMatDescr(&descrA);
    if ((status1 != CUSPARSE_STATUS_SUCCESS)){
        fprintf( stderr, "!!!! CUSPARSE cusparseCreateMatDescr (coefficient matrix) error\n" );
        return false;
    }

    /* allocate device memory for csr matrix and vectors */
    checkCudaErrors(cudaMalloc ((void**)&dev_A,  sizeof(double) * nnz));
    checkCudaErrors(cudaMalloc ((void**)&dev_iA, sizeof(int) * (n + 1)));
    checkCudaErrors(cudaMalloc ((void**)&dev_jA, sizeof(int) * nnz));
    checkCudaErrors(cudaMalloc ((void**)&dev_x0, sizeof(double) * n));
    checkCudaErrors(cudaMalloc ((void**)&dev_b,  sizeof(double) * n));
    checkCudaErrors(cudaMalloc ((void**)&dev_x,  sizeof(double) * n));
    checkCudaErrors(cudaMalloc ((void**)&dev_r0, sizeof(double) * n));
    checkCudaErrors(cudaMalloc ((void**)&dev_r,  sizeof(double) * n));
    checkCudaErrors(cudaMalloc ((void**)&dev_r_, sizeof(double) * n));
    checkCudaErrors(cudaMalloc ((void**)&dev_v,  sizeof(double) * n));
    checkCudaErrors(cudaMalloc ((void**)&dev_v_, sizeof(double) * n));
    checkCudaErrors(cudaMalloc ((void**)&dev_p,  sizeof(double) * n));
    checkCudaErrors(cudaMalloc ((void**)&dev_p_, sizeof(double) * n));
    checkCudaErrors(cudaMalloc ((void**)&dev_s,  sizeof(double) * n));
    checkCudaErrors(cudaMalloc ((void**)&dev_t,  sizeof(double) * n));
    checkCudaErrors(cudaMalloc ((void**)&dev_h,  sizeof(double) * n));


    checkCudaErrors(cudaMemcpy(dev_A, A, sizeof(double) * nnz, cudaMemcpyHostToDevice));
    checkCudaErrors(cudaMemcpy(dev_iA, iA, sizeof(int) * (n + 1), cudaMemcpyHostToDevice));
    checkCudaErrors(cudaMemcpy(dev_jA, jA, sizeof(int) * nnz, cudaMemcpyHostToDevice));
    checkCudaErrors(cudaMemcpy(dev_b, b, sizeof(double) * n, cudaMemcpyHostToDevice));


    double *x0 = new double[n]; //x0 = [1,1,1,...1]
    for (int i = 0; i < n; ++i) {
        x0[i] = 1;
    }
    checkCudaErrors(cudaMemcpy(dev_x0, x0, sizeof(double) * n, cudaMemcpyHostToDevice));
    delete[] x0;


    //checkCudaErrors(cudaMemset((void *)dev_x0,          0, sizeof(double)* n)); //x0 is zero vector
    checkCudaErrors(cudaMemset((void *)dev_x,           0, sizeof(double)* n));
    checkCudaErrors(cudaMemset((void *)dev_r0,          0, sizeof(double)* n));
    checkCudaErrors(cudaMemset((void *)dev_r,           0, sizeof(double)* n));
    checkCudaErrors(cudaMemset((void *)dev_r_,          0, sizeof(double)* n));
    checkCudaErrors(cudaMemset((void *)dev_v,           0, sizeof(double)* n));
    checkCudaErrors(cudaMemset((void *)dev_v_,          0, sizeof(double)* n));
    checkCudaErrors(cudaMemset((void *)dev_p,           0, sizeof(double)* n));
    checkCudaErrors(cudaMemset((void *)dev_p_,          0, sizeof(double)* n));
    checkCudaErrors(cudaMemset((void *)dev_s,           0, sizeof(double)* n));
    checkCudaErrors(cudaMemset((void *)dev_t,           0, sizeof(double)* n));
    checkCudaErrors(cudaMemset((void *)dev_h,           0, sizeof(double)* n));



    /* create the test matrix and vectors on the host */
    checkCudaErrors(cusparseSetMatType(descrA,CUSPARSE_MATRIX_TYPE_GENERAL));
    if (base) {
        checkCudaErrors(cusparseSetMatIndexBase(descrA,CUSPARSE_INDEX_BASE_ONE));
    }
    else{
        checkCudaErrors(cusparseSetMatIndexBase(descrA,CUSPARSE_INDEX_BASE_ZERO));
    }


    auto t1 = second();
    auto res = gpu_pbicgstab2(cublasHandle,
                              cusparseHandle,
                              n,
                              nnz,
                              descrA,
                              dev_A,
                              dev_iA,
                              dev_jA,
                              dev_x0,
                              dev_b,
                              maxit,
                              tol,
                              debug,
                              dev_x,
                              dev_r0,
                              dev_r,
                              dev_r_,
                              dev_v,
                              dev_v_,
                              dev_p,
                              dev_p_,
                              dev_s,
                              dev_t,
                              dev_h
    );
    auto t2 = second();
    *dtAlg = t2 - t1;

    checkCudaErrors(cudaDeviceSynchronize());


    /* copy the result into host memory */
    checkCudaErrors(cudaMemcpy (x, dev_x, sizeof(double) * n, cudaMemcpyDeviceToHost));


    cusparseDestroyMatDescr(descrA);
    cusparseDestroy(cusparseHandle);
    cublasDestroy(cublasHandle);



    checkCudaErrors(cudaFree(dev_A));
    checkCudaErrors(cudaFree(dev_iA));
    checkCudaErrors(cudaFree(dev_jA));
    checkCudaErrors(cudaFree(dev_x0));
    checkCudaErrors(cudaFree(dev_b));
    checkCudaErrors(cudaFree(dev_x));
    checkCudaErrors(cudaFree(dev_r0));
    checkCudaErrors(cudaFree(dev_r));
    checkCudaErrors(cudaFree(dev_r_));
    checkCudaErrors(cudaFree(dev_v));
    checkCudaErrors(cudaFree(dev_v_));
    checkCudaErrors(cudaFree(dev_p));
    checkCudaErrors(cudaFree(dev_p_));
    checkCudaErrors(cudaFree(dev_s));
    checkCudaErrors(cudaFree(dev_t));
    checkCudaErrors(cudaFree(dev_h));



    return res;
}


//TODO another stupid duplication
bool bicgstab(int n, int nnz, double *A0, int *iA0, int *jA0, double *d, double *x0, double *b, int maxit, double tol, bool debug, double *x, double *dtAlg){


    cublasHandle_t cublasHandle  = nullptr;
    cusparseHandle_t cusparseHandle  = nullptr;
    cusparseMatDescr_t descrA= nullptr;
    cusparseStatus_t status1;
    double *dev_A       = nullptr;
    int    *dev_iA = nullptr;
    int    *dev_jA = nullptr;
    double *dev_x0 = nullptr;
    double *dev_b = nullptr;
    double *dev_x = nullptr;
    double *dev_r0 = nullptr;
    double *dev_r = nullptr;
    double *dev_r_ = nullptr;
    double *dev_v = nullptr;
    double *dev_v_ = nullptr;
    double *dev_p = nullptr;
    double *dev_p_ = nullptr;
    double *dev_s = nullptr;
    double *dev_t = nullptr;
    double *dev_h = nullptr;
    double *dev_d = nullptr;



    int base = iA0[0];

    /* initialize cublas */
    if (cublasCreate(&cublasHandle) != CUBLAS_STATUS_SUCCESS) {
        fprintf( stderr, "!!!! CUBLAS initialization error\n" );
        return false;
    }
    /* initialize cusparse */
    status1 = cusparseCreate(&cusparseHandle);
    if (status1 != CUSPARSE_STATUS_SUCCESS) {
        fprintf( stderr, "!!!! CUSPARSE initialization error\n" );
        return false;
    }
    /* create three matrix descriptors */
    status1 = cusparseCreateMatDescr(&descrA);
    if ((status1 != CUSPARSE_STATUS_SUCCESS)){
        fprintf( stderr, "!!!! CUSPARSE cusparseCreateMatDescr (coefficient matrix) error\n" );
        return false;
    }

    /* allocate device memory for csr matrix and vectors */
    checkCudaErrors(cudaMalloc ((void**)&dev_A,  sizeof(double) * nnz));
    checkCudaErrors(cudaMalloc ((void**)&dev_iA, sizeof(int) * (n + 1)));
    checkCudaErrors(cudaMalloc ((void**)&dev_jA, sizeof(int) * nnz));
    checkCudaErrors(cudaMalloc ((void**)&dev_x0, sizeof(double) * n));
    checkCudaErrors(cudaMalloc ((void**)&dev_b,  sizeof(double) * n));
    checkCudaErrors(cudaMalloc ((void**)&dev_x,  sizeof(double) * n));
    checkCudaErrors(cudaMalloc ((void**)&dev_r0, sizeof(double) * n));
    checkCudaErrors(cudaMalloc ((void**)&dev_r,  sizeof(double) * n));
    checkCudaErrors(cudaMalloc ((void**)&dev_r_, sizeof(double) * n));
    checkCudaErrors(cudaMalloc ((void**)&dev_v,  sizeof(double) * n));
    checkCudaErrors(cudaMalloc ((void**)&dev_v_, sizeof(double) * n));
    checkCudaErrors(cudaMalloc ((void**)&dev_p,  sizeof(double) * n));
    checkCudaErrors(cudaMalloc ((void**)&dev_p_, sizeof(double) * n));
    checkCudaErrors(cudaMalloc ((void**)&dev_s,  sizeof(double) * n));
    checkCudaErrors(cudaMalloc ((void**)&dev_t,  sizeof(double) * n));
    checkCudaErrors(cudaMalloc ((void**)&dev_h,  sizeof(double) * n));
    checkCudaErrors(cudaMalloc ((void**)&dev_d,  sizeof(double) * n));

    checkCudaErrors(cudaMemcpy(dev_A, A0, sizeof(double) * nnz, cudaMemcpyHostToDevice));
    checkCudaErrors(cudaMemcpy(dev_iA, iA0, sizeof(int) * (n + 1), cudaMemcpyHostToDevice));
    checkCudaErrors(cudaMemcpy(dev_jA, jA0, sizeof(int) * nnz, cudaMemcpyHostToDevice));
    checkCudaErrors(cudaMemcpy(dev_b, b, sizeof(double) * n, cudaMemcpyHostToDevice));
    checkCudaErrors(cudaMemcpy(dev_d, d, sizeof(double) * n, cudaMemcpyHostToDevice));
    checkCudaErrors(cudaMemcpy(dev_x0, x0, sizeof(double) * n, cudaMemcpyHostToDevice));


    //checkCudaErrors(cudaMemset((void *)dev_x0,          0, sizeof(double)* n)); //x0 is zero vector
    checkCudaErrors(cudaMemset((void *)dev_x,           0, sizeof(double)* n));
    checkCudaErrors(cudaMemset((void *)dev_r0,          0, sizeof(double)* n));
    checkCudaErrors(cudaMemset((void *)dev_r,           0, sizeof(double)* n));
    checkCudaErrors(cudaMemset((void *)dev_r_,          0, sizeof(double)* n));
    checkCudaErrors(cudaMemset((void *)dev_v,           0, sizeof(double)* n));
    checkCudaErrors(cudaMemset((void *)dev_v_,          0, sizeof(double)* n));
    checkCudaErrors(cudaMemset((void *)dev_p,           0, sizeof(double)* n));
    checkCudaErrors(cudaMemset((void *)dev_p_,          0, sizeof(double)* n));
    checkCudaErrors(cudaMemset((void *)dev_s,           0, sizeof(double)* n));
    checkCudaErrors(cudaMemset((void *)dev_t,           0, sizeof(double)* n));
    checkCudaErrors(cudaMemset((void *)dev_h,           0, sizeof(double)* n));



    /* create the test matrix and vectors on the host */
    checkCudaErrors(cusparseSetMatType(descrA,CUSPARSE_MATRIX_TYPE_GENERAL));
    if (base) {
        checkCudaErrors(cusparseSetMatIndexBase(descrA,CUSPARSE_INDEX_BASE_ONE));
    }
    else{
        checkCudaErrors(cusparseSetMatIndexBase(descrA,CUSPARSE_INDEX_BASE_ZERO));
    }


    auto t1 = second();
    auto res = gpu_pbicgstab2(cublasHandle,
                              cusparseHandle,
                              n,
                              nnz,
                              descrA,
                              dev_A,
                              dev_iA,
                              dev_jA,
                              dev_d,
                              dev_x0,
                              dev_b,
                              maxit,
                              tol,
                              debug,
                              dev_x,
                              dev_r0,
                              dev_r,
                              dev_r_,
                              dev_v,
                              dev_v_,
                              dev_p,
                              dev_p_,
                              dev_s,
                              dev_t,
                              dev_h
    );
    auto t2 = second();
    *dtAlg = t2 - t1;

    checkCudaErrors(cudaDeviceSynchronize());


    /* copy the result into host memory */
    checkCudaErrors(cudaMemcpy (x, dev_x, sizeof(double) * n, cudaMemcpyDeviceToHost));


    cusparseDestroyMatDescr(descrA);
    cusparseDestroy(cusparseHandle);
    cublasDestroy(cublasHandle);



    checkCudaErrors(cudaFree(dev_A));
    checkCudaErrors(cudaFree(dev_iA));
    checkCudaErrors(cudaFree(dev_jA));
    checkCudaErrors(cudaFree(dev_x0));
    checkCudaErrors(cudaFree(dev_b));
    checkCudaErrors(cudaFree(dev_x));
    checkCudaErrors(cudaFree(dev_r0));
    checkCudaErrors(cudaFree(dev_r));
    checkCudaErrors(cudaFree(dev_r_));
    checkCudaErrors(cudaFree(dev_v));
    checkCudaErrors(cudaFree(dev_v_));
    checkCudaErrors(cudaFree(dev_p));
    checkCudaErrors(cudaFree(dev_p_));
    checkCudaErrors(cudaFree(dev_s));
    checkCudaErrors(cudaFree(dev_t));
    checkCudaErrors(cudaFree(dev_h));



    return res;
}


double rand_float_0_1() {
    double r = static_cast <double> (rand()) / static_cast <double> (RAND_MAX);

    return r;
}

double rand_float(double min, double max) {
	double norm = rand_float_0_1();

	return norm * (max - min) + min;
}


void gen_rand_vector(int n, double *vector, double probability_of_zero, double min, double max) {
	for (int i = 0; i < n; ++i) {
		vector[i] = rand_float_0_1() <= probability_of_zero ? 0.0 : rand_float(min, max);
	}
}



void toDenseVector(int n, int nnz, double* A, int* IA, double* out) {
    int sum = IA[0]; //base
    int count = 0;
    for (int i = 0; i < n; ++i) {
        if (IA[i + 1] - sum > 0) {
            out[i] = A[count++];
            sum = IA[i + 1];

        }
        else {
            out[i] = 0.0;
        }

    }
}





