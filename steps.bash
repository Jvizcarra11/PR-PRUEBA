################################################################################################################
#######Arquitectura multiregion en EKS con balanceo entre regiones con Route 53 y simulación de Failover########
################################################################################################################

# Consideraciones:
# - AWS CLI (aws configure)
# - eksctl
# - kubectl
# - helm
# - dominio creado en Route 53

# Despliegue de clusters en 2 regiones: us-east-1 y us-west-2
eksctl create cluster --name cluster01 --node-type t2.large --nodes 3 --nodes-min 3 --nodes-max 4 --region us-east-1 
eksctl create cluster --name cluster02 --node-type t2.large --nodes 3 --nodes-min 3 --nodes-max 4 --region us-west-2

# Establecer variables de entorno
export AWS_REGION_1=us-east-1
export AWS_REGION_2=us-west-2
export EKS_CLUSTER_1=cluster01
export EKS_CLUSTER_2=cluster02
export my_domain=tecnicode.link
export ACCOUNT_ID=891377354290

############################## INSTALACION DEL CONTROLADOR DE BALANCEO DE CARGA ######################################################
#Crear el un provedor OIDC para los clusters
eksctl utils associate-iam-oidc-provider \
  --region $AWS_REGION_1 \
  --cluster $EKS_CLUSTER_1 \
  --approve

eksctl utils associate-iam-oidc-provider \
  --region $AWS_REGION_2 \
  --cluster $EKS_CLUSTER_2 \
  --approve

#Descargar el doc de la política IAM para el AWS Load Balancer Controller
curl https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json > awslb-policy.json

#Crear la política IAM para el AWS Load Balancer Controller:
aws iam create-policy \
    --policy-name AWSLoadBalancerControllerIAMPolicy \
    --policy-document file://awslb-policy.json

#Crear un role IAM y crear un service account Kubernetes en ambos clusters
eksctl create iamserviceaccount \
  --cluster $EKS_CLUSTER_1 \
  --namespace kube-system \
  --region $AWS_REGION_1 \
  --name aws-load-balancer-controller \
  --attach-policy-arn arn:aws:iam::891377354290:policy/AWSLoadBalancerControllerIAMPolicy \
  --override-existing-serviceaccounts \
  --approve

eksctl create iamserviceaccount \
  --cluster $EKS_CLUSTER_2 \
  --namespace kube-system \
  --region $AWS_REGION_2 \
  --name aws-load-balancer-controller \
  --attach-policy-arn arn:aws:iam::891377354290:policy/AWSLoadBalancerControllerIAMPolicy \
  --override-existing-serviceaccounts \
  --approve

#Ubicarse en el entorno del primer cluster EKS
aws eks update-kubeconfig \
  --name $EKS_CLUSTER_1 \
  --region $AWS_REGION_1 

#Instalar el controlador
helm repo add eks https://aws.github.io/eks-charts
kubectl apply -k C:\Kubernetes\Proyects\PR-Prueba\crds
kubectl get crd
helm upgrade -i aws-load-balancer-controller \
  eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$EKS_CLUSTER_1 \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller

#Ubicarse en el entorno del segundo cluster EKS e instalar el controlador
aws eks update-kubeconfig \
  --name $EKS_CLUSTER_2 \
  --region $AWS_REGION_2 

helm repo add eks https://aws.github.io/eks-charts
kubectl apply -k C:\Kubernetes\Proyects\PR-Prueba\crds
kubectl get crd
helm upgrade -i aws-load-balancer-controller \
  eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$EKS_CLUSTER_2 \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller

############################################ CREACION DE LOS IMAGE ######################################################
#Creación de repositorios en ECR, ubicados en us-east-1 y us-west-2, respectivamente
aws ecr create-repository --repository-name green --region us-east-1
aws ecr create-repository --repository-name yellow --region us-west-2

#Obtener contraseñas de autenticación para ECR
aws ecr get-login-password --region us-east-1
aws ecr get-login-password --region us-west-2

#Loging hacia los repositorios de ECR
aws ecr --region us-east-1 | docker login -u AWS -p < Aqui la contraseña > 891377354290.dkr.ecr.us-east-1.amazonaws.com/green
aws ecr --region us-west-2 | docker login -u AWS -p < Aqui la contraseña > 891377354290.dkr.ecr.us-west-1.amazonaws.com/yellow

#Construir los images, etiquetarlas y subirlas desde Docker hacia ECR
cd green/
docker build . -t green
docker tag green:latest 891377354290.dkr.ecr.us-east-1.amazonaws.com/green:latest
docker push 891377354290.dkr.ecr.us-east-1.amazonaws.com/green:latest

cd yellow/
docker build . -t yellow
docker tag green:latest 891377354290.dkr.ecr.us-west-1.amazonaws.com/yellow:latest
docker push 891377354290.dkr.ecr.us-west-1.amazonaws.com/yellow:latest

############################################ DESPLIEGUE DE LA APLICACIÓN ######################################################
#Ubicarse en el entorno del primer cluster EKS
aws eks update-kubeconfig \
  --name $EKS_CLUSTER_1 \
  --region $AWS_REGION_1 

kubectl apply -f color-app-green.yaml
export Ingress_1=$(kubectl get ingress -n color-app-ingress \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

>>>> k8s-colorapp-colorapp-238b9abae5-240806911.us-east-1.elb.amazonaws.com

# --------------------------------------------------------------------------------------------
aws eks update-kubeconfig \
  --name $EKS_CLUSTER_2 \
  --region $AWS_REGION_2 

kubectl apply -f color-app-yellow.yaml
export Ingress_2=$(kubectl get ingress -n color-app-ingress \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

>>>> k8s-colorapp-colorapp-4781189419-2002793809.us-west-2.elb.amazonaws.com

########################################### CONFIGURACION DE GLOBAL ACCELERATOR #####################################################
#Creación de un Acelerador
Global_Accelerator_Arn=$(aws globalaccelerator create-accelerator \
  --name multi-region \
  --query "Accelerator.AcceleratorArn" \
  --output text)

#Se añade un Listener al acelerador para las solicitudes TCP 80
Global_Accelerator_Listerner_Arn=$(aws globalaccelerator create-listener \
  --accelerator-arn $Global_Accelerator_Arn \
  --region us-west-2 \
  --protocol TCP \
  --port-ranges FromPort=80,ToPort=80 \
  --query "Listener.ListenerArn" \
  --output text)


#Configuración de los EndPoints Group, primario
EndpointGroupArn_1=$(aws globalaccelerator create-endpoint-group \
  --region us-west-2 \
  --listener-arn $Global_Accelerator_Listerner_Arn \
  --endpoint-group-region $AWS_REGION_1 \
  --query "EndpointGroup.EndpointGroupArn" \
  --output text \
  --endpoint-configurations EndpointId=$(aws elbv2 describe-load-balancers \
    --region $AWS_REGION_1 \
    --query "LoadBalancers[?contains(DNSName, '$Ingress_1')].LoadBalancerArn" \
    --output text),Weight=128,ClientIPPreservationEnabled=True) 

#Configuración de los EndPoints Group, secundario
EndpointGroupArn_2=$(aws globalaccelerator create-endpoint-group \
  --region us-west-2 \
  --traffic-dial-percentage 0 \
  --listener-arn $Global_Accelerator_Listerner_Arn \
  --endpoint-group-region $AWS_REGION_2 \
  --query "EndpointGroup.EndpointGroupArn" \
  --output text \
  --endpoint-configurations EndpointId=$(aws elbv2 describe-load-balancers \
    --region $AWS_REGION_2 \
    --query "LoadBalancers[?contains(DNSName, '$Ingress_2')].LoadBalancerArn" \
    --output text),Weight=128,ClientIPPreservationEnabled=True) 

########################################### CONFIGURACION DE ROUTE 53 #####################################################

#Obtener el hosted zone ID del dominio creado
Route53_HostedZone=$(aws route53 list-hosted-zones \
  --query "HostedZones[?Name == '$my_domain.'].[Id]" \
  --output text | cut -d'/' -f 3)

echo $Route53_HostedZone
>>>> Z065713631FZQ1ZU72HYR

#Crear un Record en la Hosted Zone
aws route53 change-resource-record-sets --hosted-zone-id $Route53_HostedZone --change-batch file://route53-records.json

########################################### SIMULACIÓN DEL FAILOVER #####################################################
#Hacemos un escalamiento a 0 de los pods, del cluste01
aws eks update-kubeconfig \
  --name $EKS_CLUSTER_1 \
  --region $AWS_REGION_1

kubectl scale deployment green-app -n color-app --replicas=0

#Para recuperar el servicio en el cluster primario

kubectl scale deployment green-app -n color-app --replicas=3