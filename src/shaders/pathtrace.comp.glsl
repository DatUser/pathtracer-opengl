#version 450

#define DEBUG

layout (local_size_x = 16, local_size_y = 16) in;
layout (binding=0, rgba8) uniform image2D prev_frame;
layout (binding=1, rgba8) uniform image2D new_frame;
#ifdef DEBUG
layout (binding=2, rgba32f) uniform image2D debug_texture;
#endif

struct Material
{
  vec4 albedo;
  vec4 emission;
  vec4 specular;
  vec4 transmittance;  // refraction index in the last component
};

layout (std430, binding=3) buffer material_buffer { Material mats[]; };
layout (std430, binding=4) buffer vertex_buffer { vec4 vertices[]; };

struct TriangleI
{
  vec3 vertices_index;
  int mat_id;
};

layout (std430, binding=5) buffer triangle_buffer { TriangleI triangles[]; };
layout (std430, binding=6) buffer lights_buffer { TriangleI lights[]; };

struct BVHNode
{
  vec3 box_min;
  int left_child;
  vec3 box_max;
  int count;
};

layout (std430, binding=7) buffer tree_buffer { BVHNode tree[]; };


uniform int u_frame;
uniform int u_is_moving;
uniform mat4 u_cam2world;
uniform vec3 u_campos;


// *****************************************************************************
// *                              CONSTANTS                                    *
// *****************************************************************************

#define PI 					  3.1415926
#define TWO_PI 				6.2831852
#define FOUR_PI 			12.566370
#define INV_PI 				0.3183099
#define INV_TWO_PI 		0.1591549
#define INV_FOUR_PI 	0.0795775
#define EPSILON       1e-3


// *****************************************************************************
// *                                STRUCTS                                    *
// *****************************************************************************

struct Ray
{
  vec3 origin;
  vec3 dir;
};

struct Sphere
{
  vec3 center;
  float radius;
  Material mat;
};

struct Triangle
{
  vec3 p0;
  vec3 p1;
  vec3 p2;
  Material mat;
};

struct Collision
{
  float t;              // distance along ray
  vec3 p;               // world position of collision
  vec3 n;               // surface normal at collision
  float curr_ior;
  bool transmitted;
  Material mat;
  Ray ray;
  int object_index;     // index of the object
};

struct Sample
{
  vec3 value;
  float pdf;
};


// *****************************************************************************
// *                                 SCENE                                     *
// *****************************************************************************

Collision collisions[42];

vec3 ambient = vec3(0.05, 0.05, 0.05);


// *****************************************************************************
// *                                 UTILS                                     *
// *****************************************************************************

uint wang_hash(inout uint seed)
{
    seed = uint(seed ^ uint(61)) ^ uint(seed >> uint(16));
    seed *= uint(9);
    seed = seed ^ (seed >> 4);
    seed *= uint(0x27d4eb2d);
    seed = seed ^ (seed >> 15);
    return seed;
}

float RandomFloat01(inout uint state)
{
  return float(wang_hash(state)) / 4294967296.0;
}
vec3 local_to_world(vec3 local_dir, vec3 normal)
{
  vec3 binormal = normalize(
    (abs(normal.x) > abs(normal.y))
      ? vec3(normal.z, 0.0, -normal.x)
      : vec3(0.0, -normal.z, normal.y) 
  );

	vec3 tangent = cross(binormal, normal);
    
	return local_dir.x*tangent + local_dir.y*binormal + local_dir.z*normal;
}

void cartesian_to_spherical(in vec3 xyz, out float rho, out float phi, out float theta)
{
  rho = sqrt((xyz.x * xyz.x) + (xyz.y * xyz.y) + (xyz.z * xyz.z));
  phi = asin(xyz.y / rho);
	theta = atan( xyz.z, xyz.x );
}

vec3 spherical_to_cartesian(float rho, float phi, float theta)
{
  float sinTheta = sin(theta);
  return vec3(sinTheta*cos(phi), sinTheta*sin(phi), cos(theta)) * rho;
}


// *****************************************************************************
// *                             COLLISIONS                                    *
// *****************************************************************************

// Möller-Trumbore algorithm : 
//   - express problem in barycentric coordinate P = wA + uB + vC
//   - also : P = O + tD
//   - reorganise equation of collision (unknowns should be t, u, v)
//   - solve system using Cramer's rule
Collision collision(Triangle triangle, Ray ray)
{
  float eps = EPSILON;

  vec3 edge1 = triangle.p1 - triangle.p0;
  vec3 edge2 = triangle.p2 - triangle.p0;

  Collision obj_col;

  vec3 h = cross(ray.dir, edge2);
  float a = dot(edge1, h);

  // Parallel ray and triangle
  if (a > -eps && a < eps)
  {
    obj_col.t = -1;
    return obj_col;
  }

  float f = 1.0 / a;

  vec3 s = ray.origin - triangle.p0;
  float u = dot(s, h) * f;
  if (u < 0.0 || u > 1.0)
  {
    obj_col.t = -1;
    return obj_col;
  }

  vec3 q = cross(s, edge1);
  float v = dot(ray.dir, q) * f;
  if (v < 0.0 || u + v > 1.0)
  {
    obj_col.t = -1;
    return obj_col;
  }

  float t = dot(edge2, q) * f;
  if (t <= eps)
  {
    obj_col.t = -1;
    return obj_col;
  }

  obj_col.t = t;
  obj_col.p = ray.origin + ray.dir * obj_col.t; 
  obj_col.n = normalize(cross(edge1, edge2));
  obj_col.mat = triangle.mat;
  obj_col.transmitted = false;
  obj_col.ray = ray;

  return obj_col;
}

bool intersect_box(Ray ray, vec3 box_min, vec3 box_max, float tmin, float tmax)
{
  for (int a = 0; a < 3; a++)
  {
    float invD = 1.f / ray.dir[a];
    float t0 = (box_min[a] - ray.origin[a]) * invD;
    float t1 = (box_max[a] - ray.origin[a]) * invD;
    if (invD < 0.f) {
      float temp = t0;
      t0 = t1;
      t1 = temp;
    }

    tmin = t0 > tmin ? t0 : tmin;
    tmax = t1 < tmax ? t1 : tmax;

    if (tmin > tmax) return false;
  }

  return true;
}

void nearest_triangle(BVHNode node, Ray ray, inout Collision col, inout Collision min_col)
{
  for (int i = 0; i < node.count; ++i)
  {
    TriangleI t_ref = triangles[node.left_child+i];

    Triangle triangle;
    triangle.p0 = vertices[int(t_ref.vertices_index.x)].xyz;    // FIXME should pass int directly
    triangle.p1 = vertices[int(t_ref.vertices_index.y)].xyz;
    triangle.p2 = vertices[int(t_ref.vertices_index.z)].xyz;
    triangle.mat = mats[t_ref.mat_id];

    col = collision(triangle, ray);

    // Not found collision yet or new collision is nearer
    if (min_col.t == -1 || (col.t > 0 && min_col.t > col.t))
    {
      min_col = col;
    }
  }
}


// *****************************************************************************
// *                                 BVH                                      *
// *****************************************************************************

struct Stack
{
  int values[64];
  int size;
};

BVHNode pop(inout Stack stack)
{
  int node_i = stack.values[stack.size-1];
  stack.size--;
  return tree[node_i];
}

void push(inout Stack stack, int node_i)
{
  stack.values[stack.size] = node_i;
  stack.size++;
}

bool is_empty(Stack stack)
{
  return stack.size == 0;
}

Collision intersect_bvh(Ray ray)
{
  Stack stack;
  stack.size = 0;

  Collision col;
  col.t = -1;
  Collision min_col;
  min_col.t = -1;

  push(stack, 0); // push root

  float tmin = 0.001;
  float tmax = 1.0 / 0.0;

  while (!is_empty(stack))
  {
    BVHNode node = pop(stack);

    if (!intersect_box(ray, node.box_min, node.box_max, tmin, col.t != -1 ? col.t : tmax))
      continue;

    // Leaf node -> find nearest intersection in list of triangle
    if (node.count != 0)
    {
      nearest_triangle(node, ray, col, min_col);
    }
    // Internal node -> continue traversing internal boxes
    else
    {
      push(stack, node.left_child + 1);  // push right child
      push(stack, node.left_child);      // push left child
    }
  }

  return min_col;
}


// *****************************************************************************
// *                                 BSDF                                      *
// *****************************************************************************

Sample sample_hemisphere(vec3 n, vec2 u)
{
  vec2 r = vec2(u.x,u.y) * TWO_PI;
	vec3 dr = vec3(sin(r.x) * vec2(sin(r.y), cos(r.y)), cos(r.x));
	vec3 wi = dot(dr, n) * dr;

  float pdf = INV_TWO_PI;
  
  return Sample(wi, pdf);
}

Sample cosine_sample_hemisphere(vec3 n, vec2 u)
{
  vec3 dir;
  float r = sqrt(u.x);
  float phi = TWO_PI * u.y;
  dir.x = r * cos(phi);
  dir.y = r * sin(phi);
  dir.z = sqrt(max(0.0, 1.0 - dir.x * dir.x - dir.y * dir.y));
  vec3 wi = local_to_world(dir, n);

  float pdf = abs(dot(wi, n)) * INV_PI;  // FIXME only if same hemisphere

  return Sample(wi, pdf);
}

float fr_dielectric(float cos_i, float cos_t, float ior_i, float ior_t) {

  // Fresnel reflectance formulae for dielectrics : parallel and perpendicular
  // polarizations
  float r_par = ((ior_t * cos_i) - (ior_i * cos_t)) /
                ((ior_t * cos_i) + (ior_i * cos_t));
  float r_per = ((ior_i * cos_i) - (ior_t * cos_t)) /
                ((ior_i * cos_i) + (ior_t * cos_t));

  return (r_par * r_par + r_per * r_per) / 2;
}

Sample SoT_sample(inout Collision col, vec2 u)
{
  vec3 wo = -col.ray.dir;
  float cos_o = dot(wo, col.n);
  float ior_i = col.curr_ior;
  float ior_t = col.mat.transmittance[3];  // mat IoR

  bool entering = (cos_o > 0);
  if (!entering) 
  {
    float temp = ior_i;
    ior_i = ior_t;
    ior_t = ior_i;
    col.n = col.n * -1;
    cos_o *= -1;
  }

  // Snell law to compute cos_o
  float eta = ior_i / ior_t;
  float sin2_o = 1 - cos_o * cos_o;
  float sin2_i = eta * eta * sin2_o;
  float cos_i = sqrt(1 - sin2_i);

  // Fresnel reflectance
  float F;
  if (sin2_i >= 1.f)
    F = 1.f;
  else
    F = fr_dielectric(cos_o, cos_i, ior_i, ior_t);

  // Sample reflecting or transmitted ray with probability based on F 
  vec3 wi;
  float pdf;
  if (u.x < F)
  {
    wi = col.n * 2 * cos_o - wo;
    pdf = F;
  } 
  else
  {
    wi = wo * - 1 * eta + col.n * (eta * cos_o - cos_i); 
    pdf = 1 - F;
    col.transmitted = true;
    col.curr_ior = ior_t;
  }

  return Sample(wi, abs(cos_i));
}

Sample sample_bsdf(inout Collision col, inout uint rngState)
{

  vec2 u = vec2(RandomFloat01(rngState), RandomFloat01(rngState));

  // WARNING : not so sure about that -> reverse n when need to sample the other way
  if (dot(col.n, -col.ray.dir) < 0) col.n *= -1;

  // Specular / Transmissive only goes in one direction
  if (col.mat.specular != vec4(0) || col.mat.transmittance.xyz != vec3(0))
  {
    return SoT_sample(col, u);
  }
  else
  {
    return cosine_sample_hemisphere(col.n, u);
  }
}

// This is the lambert one only for now
vec3 evaluate_lambert_bsdf(Collision obj_col)
{
  return obj_col.mat.albedo.rgb * INV_PI;
}

vec3 f0 = vec3(1.00, 0.71, 0.29); //Pre-computed (default is water value)
//vec3 f0 = vec3(0.04);
float roughness = 0.2;
float metalness = 1;// = 0.1;//1 if metallic 0 otherwise

// Use dotNH for microdetails
vec3 fresnelSchlick(float dotHV, vec3 albedo)
{
  //vec3 F0 = f0;
  vec3 F0 = mix(f0, albedo, metalness);
  vec3 f90 = vec3(1.0);//Pre-computed (here we use water value)
  return F0 + (f90 - F0) * pow(1.0 - dotHV, 5.0);
}

float distribGGX(float dotNH, float alpha2)
{
  float dotNH2 = pow(dotNH, 2.0);
  float bot = dotNH2 * (alpha2 - 1.0) + 1.0;
  return alpha2 / (PI * bot * bot + EPSILON);
}

float geometrySmith(float dotNV, float dotNL, float alpha2)
{
  float kdirect = pow(roughness + 1.0, 2.0) / 8.0;
  float kIBL = alpha2 / 2.0;
  float k = kdirect;
  float Gobstruction = dotNV / (dotNV * (1.0 - k) + k);
  float Gshadowing = dotNL / (dotNL * (1.0 - k) + k);
  return Gshadowing * Gobstruction;
}

vec3 evaluate_cook_torrance_bsdf(vec3 wo, vec3 wi, Collision obj_col)
{
  //bissector of v and lightdir
  vec3 h = normalize(wi + wo);

  //Storing results
  float dotNV = max(abs(dot(obj_col.n, wo)), 0.0);
  float dotNL = max(dot(obj_col.n, wi), 0.0);
  float dotVN = max(dot(wo, obj_col.n), 0.0);
  float dotNH = max(dot(obj_col.n, h), 0.0);
  float dotLH = max(dot(wi, h), 0.0);
  float dotVH = max(dot(wo, h), 0.0);
  float alpha = roughness * roughness;
  float alpha2 = alpha * alpha;

  //Calculating Normal Distribution
  float nDistrib = distribGGX(dotNH, alpha2);

  //Calculate Schlick Fresnel approximation
  //Represents ks
  vec3 nFresnel = fresnelSchlick(dotLH, obj_col.mat.albedo.rgb); 

  //Calculate Smith GGX 
  float nGeometric = geometrySmith(dotNV, dotNL, alpha2);

  //Computing Cook-Torrance GGX model
  vec3 specular = (nDistrib * nFresnel * nGeometric) /
    (4.0 * dotNV * dotNL + EPSILON);

  //Computing diffuse Lambert
  vec3 kd = vec3(1.0);
  kd = (kd - nFresnel) * (1.0 - metalness);
  vec3 diffuse = kd * obj_col.mat.albedo.rgb / PI;

  vec3 color = (diffuse + specular) * dotNL;
  color = color / (color + vec3(1.0));
  color = pow(color, vec3(1.0 / 2.2));

  return color;
}

vec3 evaluate_sot_bsdf(Collision col)
{
  if (col.transmitted)
    return vec3(1);
    //return col.mat.transmittance.xyz; 
  else
    return col.mat.specular.xyz;
}

vec3 evaluate_bsdf(vec3 wo, vec3 wi, Collision obj_col)
{
  if (obj_col.mat.specular != vec4(0) || obj_col.mat.transmittance.xyz != vec3(0))
    return evaluate_sot_bsdf(obj_col);
  else if (obj_col.mat.albedo.rgb == vec3(0.1, 0.1, 0.69) || obj_col.mat.albedo.rgb == vec3(0.99, 0.85, 0.05)) // FIXME: Trick for presentation
    return evaluate_cook_torrance_bsdf(wo, wi, obj_col);
    else
    return evaluate_lambert_bsdf(obj_col);
}


// *****************************************************************************
// *                               LIGHTS                                      *
// *****************************************************************************

vec2 uniform_sample_triangle(vec2 u)
{
  float su0 = sqrt(u.x);
  return vec2(1 - su0, u.y * su0);
}

Sample area_sample(Triangle t, vec3 origin, inout uint rngState)
{
  vec2 u = vec2(RandomFloat01(rngState), RandomFloat01(rngState));
  vec2 b = uniform_sample_triangle(u);

  vec3 sample_pt =  t.p0 * b.x + t.p1 * b.y + t.p2 * (1 - b.x - b.y); 

  vec3 dir = normalize(sample_pt - origin);


  // Compute area of triangle
  vec3 n = cross(t.p1 - t.p0, t.p2 - t.p0);

  if (dot(dir, n) >= 0) return Sample(dir, 0); 
  
  float area_pdf = 2 / length(n);     // 1/area : uniform sampling over area
  return Sample(dir, area_pdf);
}

// *** NOTE *** : Multiple Importance Sampling (MIS) could be added here
vec3 uniform_sample_one_light(Collision obj_col, inout uint rngState)
{
  int rand_i = int(RandomFloat01(rngState) * lights.length());
  TriangleI l_ref = lights[rand_i];

  Triangle light;
  light.p0 = vertices[int(l_ref.vertices_index.x)].xyz;    // FIXME should pass int directly
  light.p1 = vertices[int(l_ref.vertices_index.y)].xyz;
  light.p2 = vertices[int(l_ref.vertices_index.z)].xyz;
  light.mat = mats[l_ref.mat_id];

  // Sample a ray direction from light to collision point
  Sample light_sample = area_sample(light, obj_col.p, rngState);
  if (light_sample.pdf == 0) return vec3(0);

  vec3 wi = light_sample.value;

  // Cannot sample if surface blocks ray from light
  if (dot(obj_col.n, -obj_col.ray.dir) < 0 && dot(obj_col.n, wi) > 0) return vec3(0);

  // Add small displacement to prevent being on the surface
  Ray ray_in = Ray(
    obj_col.p + obj_col.n * 1.0e-2 * ((dot(wi, obj_col.n) < 0) ? -1.0 : 1.0),
    wi
  );

  Collision light_col = intersect_bvh(ray_in);

  // Discard if no hit or hit non mats[1] object 
  if (light_col.t <= 0 || light_col.mat.emission.rgb == vec3(0)) return vec3(0);
  
  // Evaluate the BSDF at the object's collision 
  vec3 wo = -obj_col.ray.dir;
  vec3 f = evaluate_bsdf(wo, wi, obj_col);

  // Convert area pdf to solid angle pdf
  // Intuition: adding distance / smaller angle from point to light -> smaller angle range on point hemisphere
  float pdf = light_sample.pdf * (light_col.t * light_col.t) / abs(dot(light_col.n, -wi));

  if (f == vec3(0) || pdf == 0) return vec3(0);

  return light_col.mat.emission.rgb * f * abs(dot(wi, obj_col.n)) / pdf;
}


// *****************************************************************************
// *                               MAIN                                        *
// *****************************************************************************

vec3 pathtrace(Ray ray, inout uint rngState)
{
  vec3 L = vec3(0);                    // Total radiance estimate
  vec3 throughput = vec3(1);           // Current path throughput

  int max_bounces = 4;
  bool specular_bounce = false;
  float prev_ior = 1.0;

  for (int bounces = 0; ; bounces++)
  {
    // Intersect ray with scene
    Collision obj_col = intersect_bvh(ray);
    obj_col.curr_ior = prev_ior;

    // Stop if no collision or no more bounce
    if (obj_col.t <= 0 || bounces >= max_bounces)
    {
      L += throughput * vec3(0.05);
      break;
    }

    // Account for the emission only if :
    //  - it is the initial collision
    //  - previous was specular BSDF so no direct illumination estimate (Dirac distribution) 
    // Other cases are handled by direct lighting estimation
    if (bounces == 0)
    {
      if (obj_col.t > 0)
      {
        L += throughput * obj_col.mat.emission.rgb;
      }
      else
      {
        // TODO: infinite area light sources
        L += vec3(0);
      }
    }

    specular_bounce = (obj_col.transmitted || obj_col.mat.specular != vec4(0));

    // Direct lighting estimation at current path vertex (end of the current path = light)
    if (!specular_bounce)
      L += throughput * uniform_sample_one_light(obj_col, rngState);

    // Absorbance using Beer Law (if not set to pure transmission)
    if (prev_ior != 1.0)
      throughput *= exp(-obj_col.mat.albedo.rgb * obj_col.t);

    // Indirect lighting estimation

    // Sample the BSDF at intersection to get the new path direction
    Sample bsdf_sample = sample_bsdf(obj_col, rngState);

    //if (obj_col.transmitted) return vec3(1, 0, 0);

    vec3 wi = bsdf_sample.value;
    vec3 wo = -ray.dir;
    vec3 f = evaluate_bsdf(wo, wi, obj_col);

    prev_ior = obj_col.curr_ior;  // update IoR in case medium has changed after updating ray

    // Update how much light is received from next path vertex
    throughput *= f * abs(dot(wi, obj_col.n)) / bsdf_sample.pdf;

    // Add small displacement to prevent being on the surface
    ray = Ray(
      obj_col.p + obj_col.n * 1.0e-2 * ((dot(wi, obj_col.n) < 0) ? -1.0 : 1.0),
      wi
    );

    // Russian roulette : save computing resources by terminating paths in an unbiased way
    float p = max(throughput.r, max(throughput.g, throughput.b));
    if (RandomFloat01(rngState) > p) break;

    // Add the energy we 'lose' by randomly terminating paths
    throughput *= 1.0f / p;            
  }

  return L;
}

void main()
{
  uint rngState = uint(uint(gl_GlobalInvocationID.x) * uint(1973)
    + uint(gl_GlobalInvocationID.y) * uint(9277)
    + uint(u_frame) * uint(26699)) | uint(1);

  int width = int(gl_NumWorkGroups.x); // one workgroup = one invocation = one pixel
  int height = int(gl_NumWorkGroups.y);
  width = 1024;
  height = 1024;
  ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
  
  // Convert this pixel's screen space location to world space
  float fov = 45.0;
  float alpha = fov * PI / 180.0;
  float img_ratio = width / height;

  float pixel_x_cam = (2 * (pixel.x + 0.5) / width - 1) * tan(alpha / 2) * img_ratio;
  float pixel_y_cam = (2 * (pixel.y + 0.5) / height - 1) * tan(alpha / 2);

  vec3 pixel_cam = vec3(pixel_x_cam, pixel_y_cam, -1);
  vec4 pixel_world = u_cam2world * vec4(pixel_cam, 1);
  pixel_world.xyz /= pixel_world.w;

  vec3 pos_cam = vec3(0, 0, 0);
  vec4 pos_world = u_cam2world * vec4(pos_cam, 1);
  pos_world.xyz /= pos_world.w;

  Ray ray;
  ray.origin = pos_world.xyz;
  ray.dir = normalize(pixel_world.xyz - ray.origin);

  // Cast the ray out into the world and intersect the ray with objects

  int spp = u_is_moving == 1 ? 1 : 1;
  vec3 res = vec3(0);
  for (int i = 0; i < spp; i++)
  {
    res += 1.0 / float(spp) * pathtrace(ray, rngState);
  } 

  // Blend only if the camera is static
  vec3 acc_color;
  if (u_is_moving == 1)
  {
    acc_color = res;
  }
  else
  {
    float blend = 1.0 / (float(u_frame + 1));

    acc_color = mix(
      imageLoad(prev_frame, pixel).rgb,
      res,
      blend
    );
  }

  imageStore(new_frame, pixel, vec4(acc_color.xyz, 1.0));

  #ifdef DEBUG
  imageStore(debug_texture, pixel, vec4(res, 1.0));
  #endif
}